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
    @Published var archivedSessions: [SessionSummary] = []
    @Published var memories: [ProjectMemory] = []
    @Published var memoryConflicts: [MemoryConflict] = []
    @Published private(set) var extractingMemory: SessionID?
    @Published private(set) var processedMessages = 0
    @Published var watchedSessions: Set<SessionID> = []
    @Published var memoryUpdatePreferences: [SessionID: MemoryUpdatePreference] = [:]
    private var automaticRestartRequested = false
    private var pendingMemoryPreferenceChanges = 0
    private var automaticWorker: Task<Void,Never>?
    @Published var memoryExtractionMessage: String?
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
    private var liveCheck: Task<Void, Never>?
    private var active = false
    private var draining = false
    private var queuedSources: Set<String> = []
    private var busySources: Set<String> = []
    private var appliedModel: MemoryModelConfiguration
    private var appliedMemoryAgents: Set<String>
    private var appliedMemoryThreshold: Int
    private var appliedWatchAutomatically = true
    private var appliedScanIntervalSeconds = AppSettings.defaultScanIntervalSeconds
    private var subscription: AnyCancellable?
    private var observedRuns: [SessionID: SessionRunState] = [:]
    private var serviceGeneration = 0

    init(settings: SettingsStore) {
        appliedModel = settings.settings.memoryModel
        appliedMemoryAgents = settings.settings.memoryAutoUpdateAgents
        appliedMemoryThreshold = settings.settings.memoryAutoUpdateMessageThreshold
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
        let memoryPolicyChanged = appliedModel != newSettings.memoryModel
            || appliedMemoryAgents != newSettings.memoryAutoUpdateAgents
            || appliedMemoryThreshold != newSettings.memoryAutoUpdateMessageThreshold
        if memoryPolicyChanged || newConfiguration != configuration {
            automaticWorker?.cancel()
            appliedModel = newSettings.memoryModel
            appliedMemoryAgents = newSettings.memoryAutoUpdateAgents
            appliedMemoryThreshold = newSettings.memoryAutoUpdateMessageThreshold
            watchedSessions = []
            if let service, newConfiguration == configuration { startAutomaticWorker(service) }
        }
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
        archivedSessions = []
        memories = []
        memoryUpdatePreferences = [:]
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
            startAutomaticWorker(service)
        }
    }

    func reviewMemory(_ memory: ProjectMemory, status: String) {
        guard let service else { return }
        Task {
            do {
                try await service.setMemoryStatus(id: memory.id, status: status)
                await publishScanProgress(service)
            } catch { self.error = error.localizedDescription }
        }
    }

    func dismissConflict(_ conflict: MemoryConflict) {
        guard let service else { return }
        Task {
            do {
                try await service.dismissConflict(conflict)
                await publishScanProgress(service)
            } catch { self.error = error.localizedDescription }
        }
    }

    func replaceMemory(_ old: ProjectMemory, with new: ProjectMemory) {
        guard let service else { return }
        Task {
            do {
                try await service.replaceMemory(old.id, with: new.id)
                await publishScanProgress(service)
            } catch { self.error = error.localizedDescription }
        }
    }

    func moveMemory(_ memory: ProjectMemory, scope: String) {
        guard let service else { return }
        Task {
            do {
                try await service.setMemoryScope(id: memory.id, scope: scope)
                await publishScanProgress(service)
            } catch { self.error = error.localizedDescription }
        }
    }

    func effectiveMemoryUpdate(_ id: SessionID) -> Bool {
        (memoryUpdatePreferences[id] ?? .inherit).isEnabled(agentDefault: settingsStore.settings.memoryAutoUpdateAgents.contains(id.agent))
    }

    func setMemoryUpdate(_ id: SessionID, preference: MemoryUpdatePreference) {
        guard let service else { return }
        pendingMemoryPreferenceChanges += 1
        automaticWorker?.cancel()
        Task {
            defer {
                pendingMemoryPreferenceChanges -= 1
                if let current = self.service { startAutomaticWorker(current) }
            }
            do {
                try await service.setMemoryUpdatePreference(id, preference: preference)
                guard self.service === service else { return }
                memoryUpdatePreferences = try await service.memoryUpdatePreferences()
            } catch { memoryExtractionMessage = error.localizedDescription }
        }
    }

    private func startAutomaticWorker(_ service: HandoffService) {
        // A scan finishing during an override write must not restart old policy.
        guard pendingMemoryPreferenceChanges == 0 else { return }
        guard automaticWorker == nil else { automaticRestartRequested = true; return }
        let model = settingsStore.settings.memoryModel
        let agents = settingsStore.settings.memoryAutoUpdateAgents
        let threshold = settingsStore.settings.memoryAutoUpdateMessageThreshold
        automaticWorker = Task {
            defer {
                automaticWorker = nil
                if automaticRestartRequested {
                    automaticRestartRequested = false
                    if let current = self.service { startAutomaticWorker(current) }
                }
            }
            do {
                try Task.checkCancellation()
                try await service.synchronizeMemoryUpdates(agents: agents, model: model)
                try Task.checkCancellation()
                guard self.service === service else { return }
                memoryUpdatePreferences = try await service.memoryUpdatePreferences()
                watchedSessions = try await service.watchedSessions(model)
                revision += 1
                for (id, revision) in try await service.pendingExtractions(model, minimumNewMessages: threshold) {
                    guard self.service === service, model == settingsStore.settings.memoryModel,
                          agents == settingsStore.settings.memoryAutoUpdateAgents,
                          threshold == settingsStore.settings.memoryAutoUpdateMessageThreshold,
                          !Task.isCancelled, extractingMemory == nil else { break }
                    guard effectiveMemoryUpdate(id), watchedSessions.contains(id) else { continue }
                    extractingMemory = id
                    processedMessages = 0
                    memoryExtractionMessage = nil
                    defer { extractingMemory = nil }
                    do {
                        let key = try MemoryModelKeychain.load(endpoint: model.validatedEndpoint())
                        try await extract(service, id: id, model: model, key: key)
                        try Task.checkCancellation()
                        try await service.finishWatch(id, revision: revision, success: true)
                        memoryExtractionMessage = String(localized: "memory.semantic.success", bundle: .appResources)
                        await publishScanProgress(service)
                    } catch {
                        if Task.isCancelled { break }
                        try await service.finishWatch(id, revision: revision, success: false)
                        memoryExtractionMessage = error.localizedDescription
                    }
                }
            } catch {
                if !Task.isCancelled { memoryExtractionMessage = error.localizedDescription }
            }
        }
    }

    func memoryCoverage(_ id: SessionID) async throws -> MemoryCoverage? { try await service?.memoryCoverage(id, minimumNewMessages: settingsStore.settings.memoryAutoUpdateMessageThreshold) }

    func evidence(for memory: ProjectMemory) async throws -> String {
        guard let service, let message = memory.sourceMessageID else { throw CaptureError.invalid("Source unavailable") }
        let id = try SessionID(agent: memory.agent, externalID: memory.externalID)
        return try await service.evidence(project: memory.stableProjectID, id: id, message: message).content
    }

    private func extract(_ service: HandoffService, id: SessionID, model: MemoryModelConfiguration, key: String?) async throws {
        try await service.extractSemanticMemory(session: id, model: model, apiKey: key) { count in
            await MainActor.run { self.processedMessages = count }
        }
    }

    func extractMemory(_ id: SessionID) {
        guard let service, extractingMemory == nil else { return }
        let model = settingsStore.settings.memoryModel
        extractingMemory = id
        processedMessages = 0
        memoryExtractionMessage = nil
        Task {
            defer {
                extractingMemory = nil
                if self.service === service { startAutomaticWorker(service) }
            }
            do {
                let url = try model.validatedEndpoint()
                let key = try MemoryModelKeychain.load(endpoint: url)
                try await extract(service, id: id, model: model, key: key)
                await publishScanProgress(service)
                memoryExtractionMessage = String(localized: "memory.semantic.success", bundle: .appResources)
            } catch { memoryExtractionMessage = error.localizedDescription }
        }
    }

    private var publishingScan = false

    private func publishScanProgress(_ source: HandoffService) async {
        guard service === source, !publishingScan else { return }
        publishingScan = true
        defer { publishingScan = false }
        do {
            let loaded = try await source.displaySessions()
            let loadedArchived = try await source.displayArchivedSessions()
            let loadedMemories = try await source.displayMemories()
            let loadedConflicts = try await source.memoryConflicts()
            let loadedPreferences = try await source.memoryUpdatePreferences()
            let loadedProjects = try await source.projects()
            let loadedWorkspaces = try await source.workspaceBindings()
            let loadedStats = try await source.stats()
            guard service === source else { return }
            projects = loadedProjects
            workspaces = loadedWorkspaces
            stats = loadedStats
            noteFinishedRuns(from: loaded)
            sessions = loaded
            archivedSessions = loadedArchived
            memories = loadedMemories
            memoryConflicts = loadedConflicts
            memoryUpdatePreferences = loadedPreferences
            error = nil
            revision += 1
        } catch {
            guard service === source else { return }
            self.error = error.localizedDescription
        }
    }

    private func noteFinishedRuns(from loaded: [SessionSummary]) {
        var ended: [SessionSummary] = []
        var waiting: [SessionSummary] = []
        for session in loaded {
            guard let state = session.runState else { continue }
            let previous = observedRuns[session.id]
            if previous == .running || previous == .awaitingApproval, state == .finished || state == .aborted {
                ended.append(session)
            }
            // An approval that is still open on the first look is current work, not old history.
            if previous != .awaitingApproval, state == .awaitingApproval {
                waiting.append(session)
            }
        }
        observedRuns = Dictionary(uniqueKeysWithValues: loaded.compactMap { session in
            session.runState.map { (session.id, $0) }
        })
        for session in waiting {
            let agent = Self.agentName(session.id.agent)
            RunNotifier.shared.deliver(
                title: String(format: String(localized: "handoff.run.approvalTitle", bundle: .appResources), agent),
                subtitle: projectName(session),
                body: Self.noticeSubject(session),
                session: session.id
            )
        }
        for session in ended {
            let agent = Self.agentName(session.id.agent)
            RunNotifier.shared.deliver(
                title: String(format: String(localized: "handoff.run.endedTitle", bundle: .appResources), agent),
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

    static func agentName(_ agent: String) -> String {
        switch agent {
        case "dsh": "DeepSeek Harness"
        case "cursor": "Cursor"
        case "antigravity": "Antigravity"
        case "claude": "Claude Code"
        default: "Codex"
        }
    }

    func load(_ id: SessionID, before: Int? = nil, limit: Int = 30) async -> DisplaySessionPage? {
        do { return try await service?.displaySessionPage(id, before: before, limit: limit) } catch { self.error = error.localizedDescription; return nil }
    }

    func context(project: String, target: String) async -> String? {
        do { return try await service?.context(project: project, targetAgent: target) } catch { self.error = error.localizedDescription; return nil }
    }

    /// Clipboard text naming the open conversation so another agent can read it through MCP.
    func continuationText(project: String, session: SessionID) async -> String? {
        do {
            guard let service else { return nil }
            let brief = try await service.continuation(project: project, session: session)
            let chinese = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? true
            return ContinuationPrompt.text(brief, chinese: chinese)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private var captureSources: Set<String> {
        var sources: Set<String> = ["codex", "dsh"]
        if configuration.cursorUserRoot != nil { sources.insert("cursor") }
        if configuration.claudeRoot != nil { sources.insert("claude") }
        if configuration.antigravityRoot != nil { sources.insert("antigravity") }
        return sources
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
        if let claude = configuration.claudeRoot { paths.append(claude.path) }
        if let cursor = configuration.cursorUserRoot {
            paths.append(cursor.appendingPathComponent("globalStorage").path)
        }
        if let antigravity = configuration.antigravityRoot {
            paths.append(antigravity.appendingPathComponent("brain").path)
            paths.append(antigravity.appendingPathComponent("conversation_summaries.db").path)
            paths.append(antigravity.appendingPathComponent("conversation_summaries.db-wal").path)
            paths.append(antigravity.deletingLastPathComponent().appendingPathComponent("config/projects").path)
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func sources(for changed: [String]) -> Set<String> {
        let codexHome = configuration.codexRoot.deletingLastPathComponent().standardizedFileURL.path
        let dshHome = configuration.dshRoot.deletingLastPathComponent().standardizedFileURL.path
        let claudeRoot = configuration.claudeRoot?.standardizedFileURL.path
        let cursorHome = configuration.cursorUserRoot?.standardizedFileURL.path
        let antigravityHome = configuration.antigravityRoot?.standardizedFileURL.path
        let antigravityProjects = configuration.antigravityRoot?.deletingLastPathComponent().appendingPathComponent("config/projects").standardizedFileURL.path
        var matched: Set<String> = []
        for raw in changed {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            if path.hasPrefix(codexHome) { matched.insert("codex") }
            if path.hasPrefix(dshHome) { matched.insert("dsh") }
            if let claudeRoot, path == claudeRoot || path.hasPrefix(claudeRoot + "/") { matched.insert("claude") }
            if let cursorHome, path.hasPrefix(cursorHome) { matched.insert("cursor") }
            if let antigravityHome, path.hasPrefix(antigravityHome) { matched.insert("antigravity") }
            if let antigravityProjects, path.hasPrefix(antigravityProjects) { matched.insert("antigravity") }
        }
        return matched.isEmpty ? captureSources : matched
    }

    private func restartCapture() {
        watcher?.stop()
        watcher = nil
        cadence?.cancel()
        cadence = nil
        liveCheck?.cancel()
        liveCheck = nil
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
        // A tool approval can be waiting for the user. Check the live logs often enough to notice it.
        liveCheck = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let live = self.sessions.contains { $0.runState == .running || $0.runState == .awaitingApproval }
                if live { await self.refresh(sources: ["codex", "dsh", "antigravity", "claude"]) }
            }
        }
    }
}
