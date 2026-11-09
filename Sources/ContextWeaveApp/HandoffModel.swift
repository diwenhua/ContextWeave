import Foundation
import Combine
import ContextWeaveCore

struct SessionFocus: Equatable {
    let id: SessionID
    let token: UUID
}

@MainActor
final class HandoffModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var projects: [String] = []
    @Published var workspaces: [WorkspaceBinding] = []
    @Published var report = CaptureReport()
    @Published var stats: StoreStats?
    /// True only while a scan the user started is still running. Background scans stay quiet.
    @Published private(set) var isManualScanning = false
    @Published var error: String?
    @Published private(set) var revision = 0
    /// Set when the user opens an ended-session notification. The token changes on every click.
    @Published private(set) var sessionFocus: SessionFocus?

    private let settingsStore: SettingsStore
    private var configuration: CaptureConfiguration
    private var service: HandoffService?
    private var watcher: SourceWatcher?
    private var cadence: Task<Void, Never>?
    private var active = false
    private var draining = false
    private var queuedSources: Set<String> = []
    private var busySources: Set<String> = []
    private var appliedWatchAutomatically = true
    private var appliedScanIntervalSeconds = AppSettings.defaultScanIntervalSeconds
    private var subscription: AnyCancellable?
    private var observedRuns: [SessionID: SessionRunState] = [:]
    private var serviceGeneration = 0

    init(settings: SettingsStore) {
        settingsStore = settings
        configuration = settings.settings.captureConfiguration()
        appliedWatchAutomatically = settings.settings.watchAutomatically
        appliedScanIntervalSeconds = settings.settings.scanIntervalSeconds
        configureService(configuration)
        RunNotifier.shared.onOpen = { [weak self] agent, externalID in
            Task { @MainActor in self?.focus(agent: agent, externalID: externalID) }
        }
        subscription = settings.$settings
            .dropFirst()
            .sink { [weak self] value in
                Task { @MainActor in self?.apply(value) }
            }
    }

    func focus(agent: String, externalID: String) {
        guard let id = try? SessionID(agent: agent, externalID: externalID) else { return }
        sessionFocus = SessionFocus(id: id, token: UUID())
    }

    /// Starts capture once and refreshes; safe to call again when a window reappears.
    func start() {
        if !active {
            active = true
            restartCapture()
        }
        Task { await refresh() }
    }

    /// Applies path/cadence changes made in Settings.
    func apply(_ newSettings: AppSettings) {
        let newConfiguration = newSettings.captureConfiguration()
        let cadenceChanged = appliedWatchAutomatically != newSettings.watchAutomatically
            || appliedScanIntervalSeconds != newSettings.scanIntervalSeconds
        appliedWatchAutomatically = newSettings.watchAutomatically
        appliedScanIntervalSeconds = newSettings.scanIntervalSeconds
        guard newConfiguration != configuration else {
            // Appearance-only changes must not tear down the file watcher or scan timer.
            if active && cadenceChanged { restartCapture() }
            return
        }
        configuration = newConfiguration
        service = nil
        configureService(newConfiguration)
        sessions = []
        projects = []
        workspaces = []
        report = CaptureReport()
        stats = nil
        revision += 1
        if active {
            restartCapture()
        }
    }

    private func configureService(_ configuration: CaptureConfiguration) {
        serviceGeneration += 1
        let generation = serviceGeneration
        Task { [weak self] in
            do {
                let opened = try await Task.detached(priority: .utility) {
                    try HandoffService(configuration: configuration)
                }.value
                guard let self, self.serviceGeneration == generation else { return }
                self.service = opened
                self.error = nil
                if self.active { await self.refresh() }
            } catch {
                guard let self, self.serviceGeneration == generation else { return }
                self.service = nil
                self.error = error.localizedDescription
            }
        }
    }

    func refresh(manual: Bool = false, sources requested: Set<String>? = nil) async {
        if manual { isManualScanning = true }
        queuedSources.formUnion(requested ?? captureSources)
        guard service != nil else {
            if manual, !draining, busySources.isEmpty { isManualScanning = false }
            return
        }
        guard !draining else { return }
        draining = true
        defer {
            draining = false
            if busySources.isEmpty { isManualScanning = false }
        }
        while true {
            let ready = queuedSources.subtracting(busySources)
            if ready.isEmpty { break }
            queuedSources.subtract(ready)
            busySources.formUnion(ready)
            guard let service else { busySources.subtract(ready); break }
            let scanned = await service.scan(only: ready) { [weak self] in
                await self?.publishScanProgress(service)
            }
            busySources.subtract(ready)
            guard self.service === service else {
                queuedSources.formUnion(ready)
                continue
            }
            report = scanned
            await publishScanProgress(service)
        }
    }

    private var publishingScan = false

    private func publishScanProgress(_ source: HandoffService) async {
        guard service === source, !publishingScan else { return }
        publishingScan = true
        defer { publishingScan = false }
        do {
            let loaded = try await source.displaySessions()
            let loadedProjects = try await source.projects()
            let loadedWorkspaces = try await source.workspaceBindings()
            let loadedStats = try await source.stats()
            guard service === source else { return }
            projects = loadedProjects
            workspaces = loadedWorkspaces
            stats = loadedStats
            noteFinishedRuns(from: loaded)
            sessions = loaded
            error = nil
            revision += 1
        } catch {
            guard service === source else { return }
            self.error = error.localizedDescription
        }
    }

    private func noteFinishedRuns(from loaded: [SessionSummary]) {
        var ended: [SessionSummary] = []
        var waiting: [String] = []
        for session in loaded {
            guard let state = session.runState else { continue }
            let previous = observedRuns[session.id]
            if previous == .running || previous == .awaitingApproval, state == .finished || state == .aborted {
                ended.append(session)
            }
            if let previous, previous != .awaitingApproval, state == .awaitingApproval {
                waiting.append(Self.agentName(session.id.agent))
            }
        }
        observedRuns = Dictionary(uniqueKeysWithValues: loaded.compactMap { session in
            session.runState.map { (session.id, $0) }
        })
        for name in Self.unique(waiting) {
            RunNotifier.shared.deliver(title: name, body: String(localized: "handoff.run.approval", bundle: .module))
        }
        for session in ended {
            let agent = Self.agentName(session.id.agent)
            RunNotifier.shared.deliver(
                title: String(format: String(localized: "handoff.run.endedTitle", bundle: .module), agent),
                subtitle: projectName(session),
                body: Self.noticeSubject(session),
                session: session.id
            )
        }
    }

    private func projectName(_ session: SessionSummary) -> String? {
        let path = workspaces.first { $0.projectID == session.stableProjectID }?.path ?? session.projectID
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func noticeSubject(_ session: SessionSummary) -> String {
        let collapsed = session.title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = collapsed.isEmpty ? session.id.externalID : collapsed
        guard subject.count > 80 else { return subject }
        return String(subject.prefix(79)) + "…"
    }

    private static func unique(_ names: [String]) -> [String] {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique
    }

    static func agentName(_ agent: String) -> String {
        switch agent {
        case "dsh": "DeepSeek Harness"
        case "cursor": "Cursor"
        default: "Codex"
        }
    }

    func load(_ id: SessionID, before: Int? = nil, limit: Int = 30) async -> DisplaySessionPage? {
        do { return try await service?.displaySessionPage(id, before: before, limit: limit) } catch { self.error = error.localizedDescription; return nil }
    }

    func context(project: String, target: String) async -> String? {
        do { return try await service?.context(project: project, targetAgent: target) } catch { self.error = error.localizedDescription; return nil }
    }

    private var captureSources: Set<String> {
        configuration.cursorUserRoot == nil ? ["codex", "dsh"] : ["codex", "dsh", "cursor"]
    }

    /// Session logs, plus the agent files that hold the live conversation name and project path.
    private var watchPaths: [String] {
        let codexHome = configuration.codexRoot.deletingLastPathComponent()
        let dshHome = configuration.dshRoot.deletingLastPathComponent()
        var paths = [configuration.codexRoot.path, configuration.dshRoot.path, dshHome.appendingPathComponent("storages").path]
        paths.append(codexHome.appendingPathComponent("session_index.jsonl").path)
        if let files = try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.range(of: #"^state_\d+\.sqlite(-wal)?$"#, options: .regularExpression) != nil {
                paths.append(file.path)
            }
        }
        if let cursor = configuration.cursorUserRoot {
            paths.append(cursor.appendingPathComponent("globalStorage").path)
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func sources(for changed: [String]) -> Set<String> {
        let codexHome = configuration.codexRoot.deletingLastPathComponent().standardizedFileURL.path
        let dshHome = configuration.dshRoot.deletingLastPathComponent().standardizedFileURL.path
        let cursorHome = configuration.cursorUserRoot?.standardizedFileURL.path
        var matched: Set<String> = []
        for raw in changed {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            if path.hasPrefix(codexHome) { matched.insert("codex") }
            if path.hasPrefix(dshHome) { matched.insert("dsh") }
            if let cursorHome, path.hasPrefix(cursorHome) { matched.insert("cursor") }
        }
        return matched.isEmpty ? captureSources : matched
    }

    private func restartCapture() {
        watcher?.stop()
        watcher = nil
        cadence?.cancel()
        cadence = nil
        guard active, settingsStore.settings.watchAutomatically else { return }
        let paths = watchPaths
        let watcher = SourceWatcher(paths: paths) { [weak self] changed in
            Task { @MainActor in
                guard let self else { return }
                await self.refresh(sources: self.sources(for: changed))
            }
        }
        self.watcher = watcher
        let interval = max(15, settingsStore.settings.scanIntervalSeconds)
        cadence = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}
