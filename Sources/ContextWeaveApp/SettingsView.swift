import SwiftUI
import AppKit
import ContextWeaveCore

struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var model: HandoffModel
    @EnvironmentObject private var updates: UpdateController
    @State private var selection: Panel? = .agents

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            HStack(spacing: 0) {
                List(Panel.allCases, selection: $selection) { panel in
                    Label(panel.title, systemImage: panel.icon)
                        .tag(panel)
                }
                .listStyle(.sidebar)
                .frame(width: 188)
                Divider()
                Group {
                    switch selection ?? .agents {
                    case .agents: AgentsSettingsView()
                    case .capture: CaptureSettingsView()
                    case .memoryModel: MemoryModelSettingsView()
                    case .appearance: AppearanceSettingsView()
                    case .about: AboutSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 820, height: 580)
        .background(Weave.canvas)
        .tint(Weave.thread)
        .foregroundStyle(Weave.ink)
    }

    private enum Panel: String, CaseIterable, Identifiable {
        case agents, capture, memoryModel, appearance, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .agents: String(localized: "settings.section.agents", bundle: .appResources)
            case .capture: String(localized: "settings.section.capture", bundle: .appResources)
            case .memoryModel: String(localized: "settings.section.memoryModel", bundle: .appResources)
            case .appearance: String(localized: "settings.section.appearance", bundle: .appResources)
            case .about: String(localized: "settings.section.about", bundle: .appResources)
            }
        }

        var icon: String {
            switch self {
            case .agents: "point.3.connected.trianglepath.dotted"
            case .capture: "arrow.triangle.2.circlepath"
            case .memoryModel: "brain.head.profile"
            case .appearance: "circle.lefthalf.filled"
            case .about: "info.circle"
            }
        }
    }
}

// MARK: - Memory model

private struct MemoryModelSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var endpoint = ""
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var feedback: String?
    @State private var testing = false

    private var configuration: MemoryModelConfiguration { MemoryModelConfiguration(endpoint: endpoint, model: modelName) }

    var body: some View {
        SettingsPage(title: String(localized: "settings.section.memoryModel", bundle: .appResources), subtitle: String(localized: "settings.model.intro", bundle: .appResources)) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("settings.model.presets", bundle: .appResources)
                        Spacer()
                        Button("DeepSeek") { endpoint = "https://api.deepseek.com/chat/completions"; checkKey() }
                        Button("OpenAI") { endpoint = "https://api.openai.com/v1/chat/completions"; checkKey() }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("settings.model.endpoint", bundle: .appResources).font(.caption.weight(.semibold))
                        TextField("https://…/chat/completions", text: $endpoint).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("settings.model.name", bundle: .appResources).font(.caption.weight(.semibold))
                        TextField(String(localized: "settings.model.nameHint", bundle: .appResources), text: $modelName).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("API Key").font(.caption.weight(.semibold))
                            Spacer()
                            Text(hasKey ? "settings.model.keySaved" : "settings.model.keyMissing", bundle: .appResources).font(.caption).foregroundStyle(.secondary)
                        }
                        SecureField(String(localized: "settings.model.keyHint", bundle: .appResources), text: $apiKey).textFieldStyle(.roundedBorder)
                    }
                    Text("settings.model.privacy", bundle: .appResources).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            HStack {
                Button(String(localized: "settings.model.save", bundle: .appResources)) { save() }.buttonStyle(.borderedProminent)
                Button(String(localized: "settings.model.test", bundle: .appResources)) { test() }.disabled(testing)
                Button(String(localized: "settings.model.removeKey", bundle: .appResources)) { removeKey() }.disabled(!hasKey)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("settings.model.testHint", bundle: .appResources).font(.caption).foregroundStyle(.secondary)
            Text("settings.model.notIntegrated", bundle: .appResources).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
        }
        .onAppear { endpoint = store.settings.memoryModel.endpoint; modelName = store.settings.memoryModel.model; checkKey() }
        .onChange(of: endpoint) { _ in apiKey = ""; checkKey() }
    }

    private func checkKey() {
        do { hasKey = try configuration.validatedEndpoint().withKeychainValue != nil }
        catch { hasKey = false }
    }
    private func save() {
        do {
            let url = try configuration.validatedEndpoint()
            guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelConfigurationError.missingModel }
            if !apiKey.isEmpty { try MemoryModelKeychain.save(apiKey, endpoint: url); apiKey = "" }
            let value = configuration
            store.update { $0.memoryModel = value }
            checkKey()
            feedback = String(localized: "settings.model.saved", bundle: .appResources)
        } catch { feedback = error.localizedDescription }
    }
    private func removeKey() {
        do { try MemoryModelKeychain.remove(endpoint: configuration.validatedEndpoint()); apiKey = ""; hasKey = false; feedback = String(localized: "settings.model.removed", bundle: .appResources) }
        catch { feedback = error.localizedDescription }
    }
    private func test() {
        let current = configuration, typedKey = apiKey
        testing = true
        Task {
            defer { testing = false }
            do {
                let url = try current.validatedEndpoint()
                let key = typedKey.isEmpty ? try MemoryModelKeychain.load(endpoint: url) : typedKey
                try await MemoryModelConnection.test(configuration: current, apiKey: key)
                feedback = String(localized: "settings.model.success", bundle: .appResources)
            } catch { feedback = error.localizedDescription }
        }
    }
}

private extension URL {
    var withKeychainValue: String? { get throws { try MemoryModelKeychain.load(endpoint: self) } }
}

// MARK: - Agents

private struct AgentsSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var statuses: [AgentConnectionStatus] = []
    @State private var detectedAgents: Set<String> = []
    @State private var agentFeedback: [String: SettingsFeedback] = [:]
    @State private var feedback: SettingsFeedback?
    @State private var confirmRemoval = false
    @State private var removalAgent: String?
    @State private var showSnippets = false

    private var currentHelper: String { AppPaths.helperExecutable }
    private var helperAvailable: Bool { AppPaths.helperAvailable }
    private var anyConnected: Bool { statuses.contains { $0.state == .connected } }


    var body: some View {
        SettingsPage(
            title: String(localized: "settings.section.agents", bundle: .appResources),
            subtitle: String(localized: "settings.agents.intro", bundle: .appResources)
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(String(localized: "settings.agents.memoryThreshold", bundle: .appResources), selection: Binding(
                        get: { store.settings.memoryAutoUpdateMessageThreshold },
                        set: { value in store.update { $0.memoryAutoUpdateMessageThreshold = value } }
                    )) {
                        ForEach(AppSettings.memoryMessageThresholdChoices, id: \.self) { count in
                            Text(String(format: String(localized: "settings.agents.memoryThresholdCount", bundle: .appResources), count)).tag(count)
                        }
                    }
                    Text("settings.agents.memoryThresholdHint", bundle: .appResources)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(statuses.indices, id: \.self) { index in
                        if index > 0 { Divider() }
                        statusRow(statuses[index])
                    }
                    if statuses.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("settings.agents.checking", bundle: .appResources).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                }
                .padding(6)
            }

            HStack {
                Button(String(localized: "settings.agents.configureDetected", bundle: .appResources)) {
                    configure(agents: statuses.filter { detectedAgents.contains($0.agent) }.map(\.agent))
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!helperAvailable || detectedAgents.isEmpty)
                Button(String(localized: "settings.agents.remove", bundle: .appResources)) {
                    removalAgent = nil
                    confirmRemoval = true
                }
                .disabled(!anyConnected)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(Text("settings.agents.refresh", bundle: .appResources))
            }

            Text("settings.agents.restartHint", bundle: .appResources)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !helperAvailable {
                Label(
                    String(format: String(localized: "settings.agents.helperUnavailable", bundle: .appResources), currentHelper),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }

            Text(String(format: String(localized: "settings.agents.helper", bundle: .appResources), currentHelper))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            DisclosureGroup(isExpanded: $showSnippets) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("settings.agents.manualHint", bundle: .appResources)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: String(localized: "settings.agents.codexPath", bundle: .appResources), AppPaths.codexHome.appendingPathComponent("config.toml").path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.codexSnippet(executable: currentHelper))
                    Text(String(format: String(localized: "settings.agents.dshPath", bundle: .appResources), AppPaths.dshHome.appendingPathComponent("cordis.patch.yml").path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.dshSnippet(executable: currentHelper))
                    Text(String(format: String(localized: "settings.agents.cursorPath", bundle: .appResources), AppPaths.cursorHome.appendingPathComponent("mcp.json").path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.cursorSnippet(executable: currentHelper))
                    Text(String(format: String(localized: "settings.agents.antigravityPath", bundle: .appResources), AppPaths.antigravityConfigHome.appendingPathComponent("mcp_config.json").path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.antigravitySnippet(executable: currentHelper))
                    Text(String(format: String(localized: "settings.agents.claudePath", bundle: .appResources), ClaudePaths().configuration.path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.claudeSnippet(executable: currentHelper))
                }
                .padding(.top, 8)
            } label: {
                Text("settings.agents.manual", bundle: .appResources)
            }

            if let feedback {
                Text(feedback.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(feedback.isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refresh() }
        .confirmationDialog(
            Text(removalAgent.map {
                String(format: String(localized: "settings.agents.removeOneTitle", bundle: .appResources), HandoffModel.agentName($0))
            } ?? String(localized: "settings.agents.removeConfirmTitle", bundle: .appResources)),
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.agents.removeConfirm", bundle: .appResources), role: .destructive) { remove() }
            Button(String(localized: "settings.cancel", bundle: .appResources), role: .cancel) {}
        } message: {
            Text(removalAgent == nil
                 ? String(localized: "settings.agents.removeConfirmMessage", bundle: .appResources)
                 : String(localized: "settings.agents.removeOneMessage", bundle: .appResources))
        }
    }

    @ViewBuilder private func statusRow(_ status: AgentConnectionStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentMark(agent: status.agent, size: 20)
                Text(HandoffModel.agentName(status.agent)).font(.headline)
                Spacer()
                Label(stateLabel(status), systemImage: stateIcon(status))
                    .font(.caption)
                    .foregroundStyle(stateColor(status))
            }
            HStack {
                Text(detectedAgents.contains(status.agent)
                     ? String(localized: "settings.agents.detected", bundle: .appResources)
                     : String(localized: "settings.agents.notDetected", bundle: .appResources))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(status.state == .connected
                       ? String(localized: "settings.agents.updateOne", bundle: .appResources)
                       : String(localized: "settings.agents.configureOne", bundle: .appResources)) {
                    configure(agents: [status.agent])
                }
                .disabled(!helperAvailable || status.state == .unmanaged || status.state == .unreadable)
                if status.state == .connected {
                    Button(String(localized: "settings.agents.removeOne", bundle: .appResources), role: .destructive) {
                        removalAgent = status.agent
                        confirmRemoval = true
                    }
                }
            }
            Toggle(String(localized: "settings.agents.memoryAutoUpdate", bundle: .appResources), isOn: Binding(
                get: { store.settings.memoryAutoUpdateAgents.contains(status.agent) },
                set: { enabled in
                    store.update {
                        if enabled { $0.memoryAutoUpdateAgents.insert(status.agent) }
                        else { $0.memoryAutoUpdateAgents.remove(status.agent) }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("settings.agents.memoryAutoUpdateHint", bundle: .appResources)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.agent == "claude" {
                Text("settings.agents.claudeHint", bundle: .appResources)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = agentFeedback[status.agent] {
                Text(result.text)
                    .font(.caption)
                    .foregroundStyle(result.isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(format: String(localized: "settings.agents.config", bundle: .appResources), AppPaths.abbreviate(status.configPath)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let helper = status.helperPath {
                Text(String(format: String(localized: "settings.agents.registeredHelper", bundle: .appResources), helper))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = stateHint(status) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(status.state == .unmanaged || status.state == .unreadable ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateHint(_ status: AgentConnectionStatus) -> String? {
        switch status.state {
        case .notConfigured:
            return nil
        case .unmanaged:
            if status.agent == "claude" { return String(localized: "settings.agents.claudeUnmanagedHint", bundle: .appResources) }
            if status.agent == "cursor" {
                return String(localized: "settings.agents.cursorUnmanagedHint", bundle: .appResources)
            }
            if status.agent == "antigravity" {
                return String(localized: "settings.agents.antigravityUnmanagedHint", bundle: .appResources)
            }
            return String(localized: "settings.agents.unmanagedHint", bundle: .appResources)
        case .unreadable:
            return String(localized: "settings.agents.unreadableHint", bundle: .appResources)
        case .connected:
            guard let helper = status.helperPath else { return nil }
            if !FileManager.default.isExecutableFile(atPath: helper) {
                return String(localized: "settings.agents.helperMissingHint", bundle: .appResources)
            }
            if helper != currentHelper {
                return String(localized: "settings.agents.helperMismatchHint", bundle: .appResources)
            }
            return nil
        }
    }

    private func stateLabel(_ status: AgentConnectionStatus) -> String {
        switch status.state {
        case .notConfigured:
            return String(localized: "settings.agents.notConnected", bundle: .appResources)
        case .unmanaged:
            return String(localized: "settings.agents.unmanaged", bundle: .appResources)
        case .unreadable:
            return String(localized: "settings.agents.unreadable", bundle: .appResources)
        case .connected:
            guard let helper = status.helperPath else {
                return String(localized: "settings.agents.connected", bundle: .appResources)
            }
            if !FileManager.default.isExecutableFile(atPath: helper) {
                return String(localized: "settings.agents.helperMissing", bundle: .appResources)
            }
            if helper != currentHelper {
                return String(localized: "settings.agents.helperMismatch", bundle: .appResources)
            }
            return String(localized: "settings.agents.connected", bundle: .appResources)
        }
    }

    private func stateIcon(_ status: AgentConnectionStatus) -> String {
        switch status.state {
        case .connected: "checkmark.circle.fill"
        case .notConfigured: "circle.dashed"
        case .unmanaged: "exclamationmark.triangle.fill"
        case .unreadable: "xmark.octagon.fill"
        }
    }

    private func stateColor(_ status: AgentConnectionStatus) -> Color {
        switch status.state {
        case .connected:
            guard let helper = status.helperPath else { return .green }
            if !FileManager.default.isExecutableFile(atPath: helper) || helper != currentHelper { return .orange }
            return .green
        case .notConfigured:
            return .secondary
        case .unmanaged, .unreadable:
            return .red
        }
    }

    private func snippet(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func refresh() {
        let bundleIDs = [
            "codex": "com.openai.codex",
            "dsh": "com.deepseek.dsh",
            "cursor": "com.todesktop.230313mzl4w4u92",
            "antigravity": "com.google.antigravity",
            "claude": "com.anthropic.claudefordesktop"
        ]
        detectedAgents = Set(bundleIDs.compactMap { agent, bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil ? nil : agent
        })
        if AppPaths.claudeCLIAvailable { detectedAgents.insert("claude") }
        statuses = AgentIntegration.status(codexHome: AppPaths.codexHome, dshHome: AppPaths.dshHome)
            + [
                AgentIntegration.cursorStatus(home: AppPaths.cursorHome),
                AgentIntegration.antigravityStatus(home: AppPaths.antigravityConfigHome),
                AgentIntegration.claudeStatus(home: AppPaths.claudeConfigHome)
            ]
    }

    private func configure(agents: [String], removing: Bool = false) {
        let homes = ["codex": AppPaths.codexHome, "dsh": AppPaths.dshHome,
                     "cursor": AppPaths.cursorHome, "antigravity": AppPaths.antigravityConfigHome, "claude": AppPaths.claudeConfigHome]
        agentFeedback = [:]
        var messages: [String] = []
        var failed = false
        // Each agent has its own failure boundary; a conflict never blocks the others.
        for agent in agents {
            guard let home = homes[agent] else { continue }
            do {
                _ = try AgentIntegration.configure(agent: agent, executable: removing ? nil : currentHelper, home: home)
                let message = String(localized: removing ? "settings.agents.removedOne" : "settings.agents.configuredOne", bundle: .appResources)
                agentFeedback[agent] = SettingsFeedback(text: message)
                messages.append("\(HandoffModel.agentName(agent)): \(message)")
            } catch {
                failed = true
                agentFeedback[agent] = SettingsFeedback(text: error.localizedDescription, isError: true)
                messages.append("\(HandoffModel.agentName(agent)): \(error.localizedDescription)")
            }
        }
        feedback = SettingsFeedback(text: messages.joined(separator: "\n"), isError: failed)
        refresh()
    }

    private func remove() {
        let agents = removalAgent.map { [$0] } ?? statuses.filter { $0.state == .connected }.map(\.agent)
        configure(agents: agents, removing: true)
        removalAgent = nil
    }

}

// MARK: - Capture

private struct CaptureSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var model: HandoffModel

    var body: some View {
        SettingsPage(
            title: String(localized: "settings.section.capture", bundle: .appResources),
            subtitle: String(localized: "settings.capture.intro", bundle: .appResources)
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { store.settings.watchAutomatically },
                        set: { value in store.update { $0.watchAutomatically = value } }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("settings.capture.watch", bundle: .appResources)
                            Text("settings.capture.watchHint", bundle: .appResources)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    HStack {
                        Text("settings.capture.interval", bundle: .appResources)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.settings.scanIntervalSeconds },
                            set: { value in store.update { $0.scanIntervalSeconds = value } }
                        )) {
                            ForEach(AppSettings.scanIntervalChoices, id: \.self) { seconds in
                                Text(intervalLabel(seconds)).tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    .disabled(!store.settings.watchAutomatically)
                    Text("settings.capture.intervalHint", bundle: .appResources)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("settings.capture.status", bundle: .appResources).font(.headline)
                        if model.isManualScanning { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(String(localized: "settings.scanNow", bundle: .appResources)) {
                            Task { await model.refresh(manual: true) }
                        }
                        .disabled(model.isManualScanning)
                    }
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !model.report.errors.isEmpty {
                        DisclosureGroup(String(format: String(localized: "settings.capture.errors", bundle: .appResources), model.report.errors.count)) {
                            diagnostics(model.report.errors)
                        }
                        .font(.caption)
                    }
                    if !model.report.unavailable.isEmpty {
                        DisclosureGroup(String(format: String(localized: "settings.capture.unavailable", bundle: .appResources), model.report.unavailable.count)) {
                            diagnostics(model.report.unavailable)
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
            }
        }
    }

    private var statusText: String {
        if model.stats == nil && model.report.discovered == 0 && model.report.imported == 0
            && model.report.unchanged == 0 && model.report.errors.isEmpty {
            return String(localized: "settings.capture.never", bundle: .appResources)
        }
        return String(
            format: String(localized: "settings.capture.lastScan", bundle: .appResources),
            model.report.discovered,
            model.report.imported,
            model.report.unchanged
        )
    }

    private func intervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case 15: String(localized: "settings.capture.interval.15", bundle: .appResources)
        case 30: String(localized: "settings.capture.interval.30", bundle: .appResources)
        case 60: String(localized: "settings.capture.interval.60", bundle: .appResources)
        case 300: String(localized: "settings.capture.interval.300", bundle: .appResources)
        case 900: String(localized: "settings.capture.interval.900", bundle: .appResources)
        case 1800: String(localized: "settings.capture.interval.1800", bundle: .appResources)
        default: "\(seconds)s"
        }
    }

    private func diagnostics(_ lines: [String]) -> some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
    }
}


// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        SettingsPage(
            title: String(localized: "settings.section.appearance", bundle: .appResources),
            subtitle: String(localized: "settings.appearance.intro", bundle: .appResources)
        ) {
            GroupBox(label: Text("settings.appearance.mode", bundle: .appResources).font(.headline)) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ForEach(AppearancePreference.allCases, id: \.self) { preference in
                            optionCard(preference)
                        }
                    }
                    Text("settings.appearance.hint", bundle: .appResources)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }
        }
    }

    private func optionCard(_ preference: AppearancePreference) -> some View {
        let selected = store.settings.appearance == preference
        return Button {
            store.update { $0.appearance = preference }
        } label: {
            VStack(spacing: 8) {
                preview(preference)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Weave.line)
                    )
                Text(label(preference))
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Weave.thread : Weave.ink)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Weave.thread.opacity(0.10) : Weave.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Weave.thread : Weave.line, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label(preference)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func preview(_ preference: AppearancePreference) -> some View {
        switch preference {
        case .system:
            HStack(spacing: 0) {
                miniWindow(light: true)
                miniWindow(light: false)
            }
        case .light:
            miniWindow(light: true)
        case .dark:
            miniWindow(light: false)
        }
    }

    private func miniWindow(light: Bool) -> some View {
        let background = light ? Color(white: 0.97) : Color(white: 0.14)
        let ink = light ? Color(white: 0.16) : Color(white: 0.92)
        let accent = light
            ? Color(red: 0.06, green: 0.43, blue: 0.40)
            : Color(red: 0.40, green: 0.88, blue: 0.78)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 6, height: 6)
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.60)).frame(width: 34, height: 4)
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.22)).frame(height: 4)
            RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.22)).frame(width: 42, height: 4)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
    }

    private func label(_ preference: AppearancePreference) -> String {
        switch preference {
        case .system: String(localized: "settings.appearance.system", bundle: .appResources)
        case .light: String(localized: "settings.appearance.light", bundle: .appResources)
        case .dark: String(localized: "settings.appearance.dark", bundle: .appResources)
        }
    }
}

// MARK: - Updates and about

private struct AboutSettingsView: View {
    @EnvironmentObject private var updates: UpdateController

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(format: String(localized: "settings.about.version", bundle: .appResources), short, build)
    }

    var body: some View {
        SettingsPage(
            title: String(localized: "settings.section.about", bundle: .appResources),
            subtitle: String(localized: "settings.about.description", bundle: .appResources)
        ) {
            GroupBox(label: Text("settings.updates.title", bundle: .appResources).font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )) {
                        Text("settings.updates.automatic", bundle: .appResources)
                    }
                    .disabled(!updates.isAvailable)
                    Text("settings.updates.hint", bundle: .appResources)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(String(localized: "settings.updates.checkNow", bundle: .appResources)) {
                            updates.checkForUpdates()
                        }
                        .disabled(!updates.canCheckForUpdates)
                        Spacer()
                    }
                    if !updates.isAvailable {
                        Text("settings.updates.unavailable", bundle: .appResources)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox(label: Text("settings.about.title", bundle: .appResources).font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                            .resizable()
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ContextWeave").font(.title3.bold())
                            Text(version).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    LabeledContent(String(localized: "settings.about.license", bundle: .appResources), value: "MIT").font(.caption)
                }
                .padding(8)
            }
        }
    }

}

// MARK: - Shared pieces

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title2.bold())
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsFeedback {
    let text: String
    var isError = false
}
