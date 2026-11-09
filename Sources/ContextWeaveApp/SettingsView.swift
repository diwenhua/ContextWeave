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
        case agents, capture, appearance, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .agents: String(localized: "settings.section.agents", bundle: .module)
            case .capture: String(localized: "settings.section.capture", bundle: .module)
            case .appearance: String(localized: "settings.section.appearance", bundle: .module)
            case .about: String(localized: "settings.section.about", bundle: .module)
            }
        }

        var icon: String {
            switch self {
            case .agents: "point.3.connected.trianglepath.dotted"
            case .capture: "arrow.triangle.2.circlepath"
            case .appearance: "circle.lefthalf.filled"
            case .about: "info.circle"
            }
        }
    }
}

// MARK: - Agents

private struct AgentsSettingsView: View {
    @State private var statuses: [AgentConnectionStatus] = []
    @State private var feedback: SettingsFeedback?
    @State private var confirmRemoval = false
    @State private var showSnippets = false

    private var currentHelper: String { AppPaths.helperExecutable }
    private var helperAvailable: Bool { AppPaths.helperAvailable }
    private var anyConnected: Bool { statuses.contains { $0.state == .connected } }
    private var hasBlockingIssue: Bool { statuses.contains { $0.state == .unmanaged || $0.state == .unreadable } }

    var body: some View {
        SettingsPage(
            title: String(localized: "settings.section.agents", bundle: .module),
            subtitle: String(localized: "settings.agents.intro", bundle: .module)
        ) {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(statuses.indices, id: \.self) { index in
                        if index > 0 { Divider() }
                        statusRow(statuses[index])
                    }
                    if statuses.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("settings.agents.checking", bundle: .module).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                }
                .padding(6)
            }

            HStack {
                Button(connectTitle) { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!helperAvailable || hasBlockingIssue)
                Button(String(localized: "settings.agents.remove", bundle: .module)) {
                    confirmRemoval = true
                }
                .disabled(!anyConnected || hasBlockingIssue)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(Text("settings.agents.refresh", bundle: .module))
            }

            if let hint = blockingHint {
                Label(hint, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !helperAvailable {
                Label(
                    String(format: String(localized: "settings.agents.helperUnavailable", bundle: .module), currentHelper),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }

            Text(String(format: String(localized: "settings.agents.helper", bundle: .module), currentHelper))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            DisclosureGroup(isExpanded: $showSnippets) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("settings.agents.manualHint", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: String(localized: "settings.agents.codexPath", bundle: .module), AppPaths.codexHome.appendingPathComponent("config.toml").path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.codexSnippet(executable: currentHelper))
                    Text(String(format: String(localized: "settings.agents.dshPath", bundle: .module), AppPaths.dshHome.appendingPathComponent("cordis.patch.yml").path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.dshSnippet(executable: currentHelper))
                    Text(String(format: String(localized: "settings.agents.cursorPath", bundle: .module), AppPaths.cursorHome.appendingPathComponent("mcp.json").path))
                        .font(.caption.bold())
                    snippet(AgentIntegration.cursorSnippet(executable: currentHelper))
                }
                .padding(.top, 8)
            } label: {
                Text("settings.agents.manual", bundle: .module)
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
            Text("settings.agents.removeConfirmTitle", bundle: .module),
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.agents.removeConfirm", bundle: .module), role: .destructive) { remove() }
            Button(String(localized: "settings.cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text("settings.agents.removeConfirmMessage", bundle: .module)
        }
    }

    private var connectTitle: String {
        anyConnected
            ? String(localized: "settings.agents.update", bundle: .module)
            : String(localized: "settings.agents.connect", bundle: .module)
    }

    @ViewBuilder private func statusRow(_ status: AgentConnectionStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentMark(agent: status.agent, size: 20)
                Text(status.agent == "dsh" ? "DeepSeek Harness" : status.agent == "cursor" ? "Cursor" : "Codex").font(.headline)
                Spacer()
                Label(stateLabel(status), systemImage: stateIcon(status))
                    .font(.caption)
                    .foregroundStyle(stateColor(status))
            }
            Text(String(format: String(localized: "settings.agents.config", bundle: .module), AppPaths.abbreviate(status.configPath)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let helper = status.helperPath {
                Text(String(format: String(localized: "settings.agents.registeredHelper", bundle: .module), helper))
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

    private var blockingHint: String? {
        statuses.first(where: { $0.state == .unmanaged || $0.state == .unreadable }).flatMap { stateHint($0) }
    }

    private func stateHint(_ status: AgentConnectionStatus) -> String? {
        switch status.state {
        case .notConfigured:
            return nil
        case .unmanaged:
            if status.agent == "cursor" {
                return String(localized: "settings.agents.cursorUnmanagedHint", bundle: .module)
            }
            return String(localized: "settings.agents.unmanagedHint", bundle: .module)
        case .unreadable:
            return String(localized: "settings.agents.unreadableHint", bundle: .module)
        case .connected:
            guard let helper = status.helperPath else { return nil }
            if !FileManager.default.isExecutableFile(atPath: helper) {
                return String(localized: "settings.agents.helperMissingHint", bundle: .module)
            }
            if helper != currentHelper {
                return String(localized: "settings.agents.helperMismatchHint", bundle: .module)
            }
            return nil
        }
    }

    private func stateLabel(_ status: AgentConnectionStatus) -> String {
        switch status.state {
        case .notConfigured:
            return String(localized: "settings.agents.notConnected", bundle: .module)
        case .unmanaged:
            return String(localized: "settings.agents.unmanaged", bundle: .module)
        case .unreadable:
            return String(localized: "settings.agents.unreadable", bundle: .module)
        case .connected:
            guard let helper = status.helperPath else {
                return String(localized: "settings.agents.connected", bundle: .module)
            }
            if !FileManager.default.isExecutableFile(atPath: helper) {
                return String(localized: "settings.agents.helperMissing", bundle: .module)
            }
            if helper != currentHelper {
                return String(localized: "settings.agents.helperMismatch", bundle: .module)
            }
            return String(localized: "settings.agents.connected", bundle: .module)
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
        statuses = AgentIntegration.status(codexHome: AppPaths.codexHome, dshHome: AppPaths.dshHome)
            + [AgentIntegration.cursorStatus(home: AppPaths.cursorHome)]
    }

    private func connect() {
        do {
            var messages = try AgentIntegration.connect(
                executable: currentHelper,
                codexHome: AppPaths.codexHome,
                dshHome: AppPaths.dshHome
            )
            messages += try AgentIntegration.configureCursor(executable: currentHelper, home: AppPaths.cursorHome)
            feedback = SettingsFeedback(text: messages.joined(separator: "\n"))
        } catch {
            feedback = SettingsFeedback(text: error.localizedDescription, isError: true)
        }
        refresh()
    }

    private func remove() {
        do {
            var messages = try AgentIntegration.remove(codexHome: AppPaths.codexHome, dshHome: AppPaths.dshHome)
            messages += try AgentIntegration.configureCursor(executable: nil, home: AppPaths.cursorHome)
            feedback = SettingsFeedback(text: messages.joined(separator: "\n"))
        } catch {
            feedback = SettingsFeedback(text: error.localizedDescription, isError: true)
        }
        refresh()
    }
}

// MARK: - Capture

private struct CaptureSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var model: HandoffModel

    var body: some View {
        SettingsPage(
            title: String(localized: "settings.section.capture", bundle: .module),
            subtitle: String(localized: "settings.capture.intro", bundle: .module)
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { store.settings.watchAutomatically },
                        set: { value in store.update { $0.watchAutomatically = value } }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("settings.capture.watch", bundle: .module)
                            Text("settings.capture.watchHint", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    HStack {
                        Text("settings.capture.interval", bundle: .module)
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
                    Text("settings.capture.intervalHint", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("settings.capture.status", bundle: .module).font(.headline)
                        if model.isManualScanning { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(String(localized: "settings.scanNow", bundle: .module)) {
                            Task { await model.refresh(manual: true) }
                        }
                        .disabled(model.isManualScanning)
                    }
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !model.report.errors.isEmpty {
                        DisclosureGroup(String(format: String(localized: "settings.capture.errors", bundle: .module), model.report.errors.count)) {
                            diagnostics(model.report.errors)
                        }
                        .font(.caption)
                    }
                    if !model.report.unavailable.isEmpty {
                        DisclosureGroup(String(format: String(localized: "settings.capture.unavailable", bundle: .module), model.report.unavailable.count)) {
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
            return String(localized: "settings.capture.never", bundle: .module)
        }
        return String(
            format: String(localized: "settings.capture.lastScan", bundle: .module),
            model.report.discovered,
            model.report.imported,
            model.report.unchanged
        )
    }

    private func intervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case 15: String(localized: "settings.capture.interval.15", bundle: .module)
        case 30: String(localized: "settings.capture.interval.30", bundle: .module)
        case 60: String(localized: "settings.capture.interval.60", bundle: .module)
        case 300: String(localized: "settings.capture.interval.300", bundle: .module)
        case 900: String(localized: "settings.capture.interval.900", bundle: .module)
        case 1800: String(localized: "settings.capture.interval.1800", bundle: .module)
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
            title: String(localized: "settings.section.appearance", bundle: .module),
            subtitle: String(localized: "settings.appearance.intro", bundle: .module)
        ) {
            GroupBox(label: Text("settings.appearance.mode", bundle: .module).font(.headline)) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ForEach(AppearancePreference.allCases, id: \.self) { preference in
                            optionCard(preference)
                        }
                    }
                    Text("settings.appearance.hint", bundle: .module)
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
        case .system: String(localized: "settings.appearance.system", bundle: .module)
        case .light: String(localized: "settings.appearance.light", bundle: .module)
        case .dark: String(localized: "settings.appearance.dark", bundle: .module)
        }
    }
}

// MARK: - Updates and about

private struct AboutSettingsView: View {
    @EnvironmentObject private var updates: UpdateController
    @EnvironmentObject private var store: SettingsStore

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(format: String(localized: "settings.about.version", bundle: .module), short, build)
    }

    var body: some View {
        SettingsPage(
            title: String(localized: "settings.section.about", bundle: .module),
            subtitle: String(localized: "settings.about.description", bundle: .module)
        ) {
            GroupBox(label: Text("settings.updates.title", bundle: .module).font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )) {
                        Text("settings.updates.automatic", bundle: .module)
                    }
                    .disabled(!updates.isAvailable)
                    Text("settings.updates.hint", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(String(localized: "settings.updates.checkNow", bundle: .module)) {
                            updates.checkForUpdates()
                        }
                        .disabled(!updates.canCheckForUpdates)
                        Spacer()
                    }
                    if !updates.isAvailable {
                        Text("settings.updates.unavailable", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox(label: Text("settings.about.title", bundle: .module).font(.headline)) {
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
                    infoRow(String(localized: "settings.about.helper", bundle: .module), AppPaths.helperExecutable, monospaced: true)
                    infoRow(String(localized: "settings.about.database", bundle: .module), AppPaths.abbreviate(store.settings.resolvedPaths().database.path), monospaced: true)
                    infoRow(String(localized: "settings.about.settingsFile", bundle: .module), AppPaths.abbreviate(AppPaths.settingsURL.path), monospaced: true)
                    infoRow(String(localized: "settings.about.license", bundle: .module), "MIT")
                }
                .padding(8)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
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
