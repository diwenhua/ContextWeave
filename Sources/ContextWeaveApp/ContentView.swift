import SwiftUI
import AppKit
import ContextWeaveCore

struct ContentView: View {
    @EnvironmentObject private var model: HandoffModel
    @State private var selected: SessionID?
    @State private var collapsedProjects: Set<String> = []
    @State private var expandedSessionProjects: Set<String> = []
    private let sessionPreviewLimit = 3
    @State private var session: Session?
    @State private var target = "dsh"
    @State private var sessionStart = 0
    @State private var sessionLoadGeneration = UUID()
    @State private var loadingEarlier = false
    @State private var copied = false
    @State private var agentFilter: String?
    @State private var scrollTarget: SessionID?
    @State private var isAtBottom = true
    @State private var selectedTab: MainTab = .sessions
    private static let transcriptBottomID = "transcript-bottom"
    private static let transcriptTopID = "transcript-top"
    @AppStorage("contextweave.agentRailShowsNames") private var showsAgentNames = true

    private var filtered: [SessionSummary] {
        model.sessions.filter { item in
            agentFilter == nil || item.source.id.agent == agentFilter
        }
    }
    private struct ProjectGroup: Identifiable {
        let id: String
        let label: String
        let sessions: [SessionSummary]
    }
    private var projectGroups: [ProjectGroup] {
        let buckets = Dictionary(grouping: filtered) { item -> String in
            if let id = item.stableProjectID, !id.isEmpty { return id }
            if let path = item.projectID, !path.isEmpty { return path }
            return ""
        }
        return buckets.map { key, sessions in
            let ordered = sessions.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return ProjectGroup(id: key, label: projectLabel(for: ordered[0]), sessions: ordered)
        }
        .sorted { lhs, rhs in
            let left = lhs.sessions.map(\.lastActivity).max() ?? 0
            let right = rhs.sessions.map(\.lastActivity).max() ?? 0
            if left != right { return left > right }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }
    private struct ProjectChoice: Identifiable {
        let id: String
        let label: String
    }
    private var projectChoices: [ProjectChoice] {
        let grouped = Dictionary(grouping: model.workspaces, by: \.projectID)
        let names = grouped.mapValues { bindings in
            bindings.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted().first ?? "Project"
        }
        let counts = Dictionary(grouping: names.values, by: { $0 }).mapValues(\.count)
        return names.map { id, name in
            ProjectChoice(id: id, label: (counts[name] ?? 0) > 1 ? "\(name) · \(id.prefix(8))" : name)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
    private func projectLabel(_ id: String?) -> String {
        guard let id, let label = projectChoices.first(where: { $0.id == id })?.label else { return String(localized: "handoff.noProject", bundle: .module) }
        return label
    }
    private func projectLabel(for item: SessionSummary) -> String {
        if let id = item.stableProjectID, let label = projectChoices.first(where: { $0.id == id })?.label { return label }
        if let path = item.projectID, !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
        return String(localized: "handoff.noProject", bundle: .module)
    }

    var body: some View {
        HStack(spacing: 0) {
            AppRail(selectedTab: $selectedTab)
            content
        }
        .background(Weave.canvas)
        .tint(Weave.thread)
        .foregroundStyle(Weave.ink)
        .onAppear {
            WindowSizing.applyDefaultIfNeeded()
            if let request = model.sessionFocus { reveal(request.id) }
        }
        .onChange(of: model.sessionFocus) { request in
            guard let request else { return }
            reveal(request.id)
        }
    }

    @ViewBuilder private var content: some View {
        switch selectedTab {
        case .sessions: sessionsPage
        }
    }

    private var sessionsPage: some View {
        VStack(spacing: 0) {
            HSplitView {
                sessionList
                transcript
            }
        }
        .task { model.start() }
        .onChange(of: model.revision) { _ in
            Task {
                guard let selected, session?.source.id == selected, !loadingEarlier else { return }
                let generation = UUID()
                sessionLoadGeneration = generation
                let page = await model.load(selected)
                guard self.selected == selected, sessionLoadGeneration == generation, let page else { return }
                if let current = session, current.source.id == selected,
                   page.start <= sessionStart + current.messages.count {
                    let newIDs = Set(page.session.messages.map(\.id))
                    let earlier = current.messages.filter { !newIDs.contains($0.id) }
                    session = Session(source: page.session.source, projectID: page.session.projectID, messages: earlier + page.session.messages, stableProjectID: page.session.stableProjectID, runState: page.session.runState)
                    sessionStart = min(sessionStart, page.start)
                } else {
                    session = page.session
                    sessionStart = page.start
                }
            }
        }
        .task(id: selected) {
            copied = false
            session = nil
            sessionStart = 0
            loadingEarlier = false
            isAtBottom = true
            let generation = UUID()
            sessionLoadGeneration = generation
            if let selected {
                let page = await model.load(selected)
                guard self.selected == selected, sessionLoadGeneration == generation, let page else { return }
                session = page.session
                sessionStart = page.start
                target = selected.agent == "codex" ? "dsh" : "codex"
            }
        }
        .onChange(of: agentFilter) { _ in
            if let selected, !filtered.contains(where: { $0.id == selected }) { self.selected = nil }
        }
    }

    private var sessionList: some View {
        HStack(spacing: 0) {
            ProjectAgentRail(agentFilter: $agentFilter)
            projectList
        }
        .frame(
            minWidth: showsAgentNames ? 468 : 340,
            idealWidth: showsAgentNames ? 488 : 360,
            maxWidth: showsAgentNames ? 488 : 360
        )
        .animation(.easeInOut(duration: 0.16), value: showsAgentNames)
        .background(Weave.sidebar)
    }

    private func groupKey(_ item: SessionSummary) -> String {
        if let id = item.stableProjectID, !id.isEmpty { return id }
        if let path = item.projectID, !path.isEmpty { return path }
        return ""
    }

    private func reveal(_ id: SessionID) {
        selectedTab = .sessions
        if agentFilter != nil, agentFilter != id.agent { agentFilter = nil }
        if let item = model.sessions.first(where: { $0.id == id }) {
            let group = groupKey(item)
            collapsedProjects.remove(group)
            let rank = model.sessions
                .filter { groupKey($0) == group }
                .sorted { $0.lastActivity > $1.lastActivity }
                .firstIndex { $0.id == id } ?? 0
            if rank >= sessionPreviewLimit { expandedSessionProjects.insert(group) }
        }
        selected = id
        scrollTarget = id
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "ContextWeave" && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if projectGroups.isEmpty {
                    Text("handoff.hint", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(Weave.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                }
                ForEach(projectGroups) { group in
                    let expanded = !collapsedProjects.contains(group.id)
                    VStack(alignment: .leading, spacing: 8) {
                        ProjectSectionHeader(label: group.label, count: group.sessions.count, expanded: expanded) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                if expanded { collapsedProjects.insert(group.id) } else { collapsedProjects.remove(group.id) }
                            }
                        }
                        if expanded {
                            let showAll = expandedSessionProjects.contains(group.id)
                            let visible = showAll ? group.sessions : Array(group.sessions.prefix(sessionPreviewLimit))
                            ForEach(visible) { item in
                                Button { selected = item.id } label: {
                                    SessionCard(item: item, active: selected == item.id)
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                                .accessibilityAddTraits(selected == item.id ? .isSelected : [])
                            }
                            if group.sessions.count > sessionPreviewLimit {
                                SessionOverflowButton(
                                    expanded: showAll,
                                    hiddenCount: group.sessions.count - sessionPreviewLimit
                                ) {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        if showAll { expandedSessionProjects.remove(group.id) } else { expandedSessionProjects.insert(group.id) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Weave.card.opacity(0.28))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Weave.line, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .onChange(of: scrollTarget) { id in
            guard let id else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                transcriptBar(session)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if sessionStart > 0 {
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.transcriptTopID)
                                    .onAppear { autoLoadEarlier(session) }
                                Button(String(localized: "handoff.earlier", bundle: .module)) {
                                    Task { await loadEarlier(session.source.id) }
                                }
                                .disabled(loadingEarlier)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                            }
                            ForEach(TranscriptBuilder.entries(from: session.messages)) { entry in
                                switch entry {
                                case .message(let message):
                                    MessageCard(message: message, agent: session.source.id.agent)
                                case .tool(let activity):
                                    ToolCallCard(
                                        activity: activity,
                                        sessionActive: session.runState == .running || session.runState == .awaitingApproval
                                    )
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(Self.transcriptBottomID)
                                .onAppear { isAtBottom = true }
                                .onDisappear { isAtBottom = false }
                        }
                        .padding(22)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .id(selected)
                    .onAppear {
                        isAtBottom = true
                        initialScrollToBottom(proxy)
                    }
                    .onChange(of: session.messages.last?.id) { _ in
                        if isAtBottom { scrollToTranscriptBottom(proxy) }
                    }
                    .onChange(of: session.messages.count) { _ in
                        if isAtBottom { scrollToTranscriptBottom(proxy) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !isAtBottom {
                            Button {
                                isAtBottom = true
                                scrollToTranscriptBottom(proxy)
                            } label: {
                                Label(String(localized: "handoff.jumpToLatest", bundle: .module), systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Weave.card))
                                    .overlay(Capsule().strokeBorder(Weave.line))
                            }
                            .buttonStyle(.plain)
                            .padding(14)
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: isAtBottom)
                }
            } else {
                emptyTranscript
            }
        }
        .frame(minWidth: 560, idealWidth: 820, maxWidth: .infinity, maxHeight: .infinity)
        .background(Weave.canvas)
    }

    private func autoLoadEarlier(_ session: Session) {
        guard !isAtBottom, sessionStart > 0, !loadingEarlier else { return }
        Task { await loadEarlier(session.source.id) }
    }

    private func initialScrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            for delay in [0, 80, 250, 600] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
            }
        }
    }

    private func scrollToTranscriptBottom(_ proxy: ScrollViewProxy, animated: Bool = true, delay: Int = 30) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
            }
        }
    }

    private func loadEarlier(_ id: SessionID) async {
        guard sessionStart > 0, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let before = sessionStart
        let generation = sessionLoadGeneration
        guard let page = await model.load(id, before: before), selected == id,
              generation == sessionLoadGeneration, let current = session, current.source.id == id,
              sessionStart == before else { return }
        session = Session(source: current.source, projectID: current.projectID, messages: page.session.messages + current.messages, stableProjectID: current.stableProjectID, runState: current.runState)
        sessionStart = page.start
    }

    private func transcriptBar(_ session: Session) -> some View {
        HStack(spacing: 10) {
            AgentPill(agent: session.source.id.agent)
            if let state = model.sessions.first(where: { $0.id == session.source.id })?.runState {
                RunBadge(state: state)
            }
            Text(projectLabel(session.stableProjectID))
                .font(.caption)
                .foregroundStyle(Weave.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Picker(String(localized: "handoff.target", bundle: .module), selection: $target) {
                Text("Codex").tag("codex")
                Text("DeepSeek Harness").tag("dsh")
                Text("Cursor").tag("cursor")
            }
            .pickerStyle(.menu)
            .frame(width: 168)
            Button {
                guard let projectID = session.stableProjectID else { return }
                Task {
                    if let context = await model.context(project: projectID, target: target) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(context, forType: .string)
                        copied = true
                    }
                }
            } label: {
                Label(copied ? String(localized: "handoff.copied", bundle: .module) : String(localized: "handoff.copy", bundle: .module), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(session.stableProjectID == nil || !model.workspaces.contains(where: { $0.projectID == session.stableProjectID }))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Weave.card.opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(Weave.line).frame(height: 1) }
    }

    private var emptyTranscript: some View {
        EmptyHandoff()
    }

}

private struct EmptyHandoff: View {
    private let agents = ["codex", "dsh", "cursor"]

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Capsule()
                    .fill(Weave.thread.opacity(0.55))
                    .frame(width: 210, height: 1.5)
                HStack(spacing: 40) {
                    ForEach(agents, id: \.self) { agent in
                        AgentMark(agent: agent, size: 44)
                            .padding(5)
                            .background(Circle().fill(Weave.canvas))
                            .overlay(Circle().strokeBorder(Weave.line, lineWidth: 1))
                    }
                }
            }
            Text("welcome.tagline", bundle: .module)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Weave.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -12)
    }
}

private struct ProjectSectionHeader: View {
    let label: String
    let count: Int
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Weave.muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Weave.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Weave.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Weave.canvas.opacity(0.72)))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Weave.card.opacity(0.75) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(count)"))
        .accessibilityAddTraits(expanded ? .isSelected : AccessibilityTraits())
    }
}

private struct SessionOverflowButton: View {
    let expanded: Bool
    let hiddenCount: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                Text(expanded
                    ? String(localized: "handoff.sessions.less", bundle: .module)
                    : String(localized: "handoff.sessions.more", bundle: .module))
                    .lineLimit(1)
                if !expanded {
                    Text("\(hiddenCount)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(Weave.thread)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Weave.thread.opacity(hovering ? 0.22 : 0.14)))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovering ? Weave.thread : Weave.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Weave.thread.opacity(0.12) : Weave.canvas.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Weave.thread.opacity(0.5) : Weave.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RunBadge: View {
    let state: SessionRunState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var title: String {
        switch state {
        case .running: String(localized: "handoff.run.running", bundle: .module)
        case .awaitingApproval: String(localized: "handoff.run.approval", bundle: .module)
        case .finished, .aborted: String(localized: "handoff.run.ended", bundle: .module)
        }
    }

    private var color: Color {
        switch state {
        case .running: Weave.thread
        case .awaitingApproval: Weave.harness
        case .finished, .aborted: Weave.muted
        }
    }
}

private struct SessionCard: View {
    let item: SessionSummary
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.lastActivity > 0 {
                    Text(Self.relative(item.lastActivity))
                        .font(.caption)
                        .foregroundStyle(Weave.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: 8) {
                AgentPill(agent: item.source.id.agent)
                Spacer(minLength: 8)
                Text("\(item.messageCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Weave.agent(item.source.id.agent))
                    .fixedSize()
                if let state = item.runState {
                    RunBadge(state: state)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? Weave.card : Weave.canvas.opacity(0.55))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Weave.agent(item.source.id.agent).opacity(active ? 1 : 0.45))
                .frame(width: 3)
                .padding(.vertical, 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Weave.agent(item.source.id.agent).opacity(0.75) : Weave.line, lineWidth: active ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static func relative(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000).formatted(.relative(presentation: .named))
    }
}

private struct AgentPill: View {
    let agent: String
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            AgentMark(agent: agent, size: compact ? 14 : 16)
            Text(agent == "dsh" ? "DeepSeek Harness" : agent == "cursor" ? "Cursor" : "Codex")
                .lineLimit(1)
        }
        .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
        .foregroundStyle(Weave.agent(agent))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(Weave.agent(agent).opacity(0.14)))
    }
}

private struct AppMark: View {
    var size: CGFloat = 26

    var body: some View {
        icon
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var icon: Image {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
        } else {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
        }
    }
}


private struct AppRail: View {
    @Binding var selectedTab: MainTab
    @State private var isHoveringSettings = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Weave.card)
                AppMark(size: 24)
            }
            .frame(width: 36, height: 36)
            .overlay(Circle().strokeBorder(Weave.line))
            .padding(.top, 12)
            Rectangle()
                .fill(Weave.line)
                .frame(width: 24, height: 1)
                .padding(.top, 12)
            VStack(spacing: 6) {
                ForEach(MainTab.allCases) { tab in
                    AppTabButton(tab: tab, selected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
            Button {
                SettingsWindow.open()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHoveringSettings ? Weave.thread.opacity(0.16) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHoveringSettings ? Weave.thread : Weave.muted)
            .onHover { isHoveringSettings = $0 }
            .help(Text("settings.open", bundle: .module))
            .accessibilityLabel(Text("settings.open", bundle: .module))
            .padding(.bottom, 12)
        }
        .frame(width: 52)
        .frame(maxHeight: .infinity)
        .background(Weave.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Weave.line).frame(width: 1) }
    }
}

private struct ProjectAgentRail: View {
    @Binding var agentFilter: String?
    @EnvironmentObject private var model: HandoffModel
    @AppStorage("contextweave.agentRailShowsNames") private var showsNames = true
    @State private var isHoveringRefresh = false
    @State private var isHoveringCollapse = false

    var body: some View {
        VStack(spacing: 4) {
            AgentRailButton(
                symbol: "circle.grid.2x2",
                name: String(localized: "handoff.agent.rail.all", bundle: .module),
                compact: !showsNames,
                tint: Weave.thread,
                selected: agentFilter == nil,
                help: String(localized: "handoff.agent.all", bundle: .module)
            ) { agentFilter = nil }
            AgentRailButton(
                agent: "codex",
                name: "Codex",
                compact: !showsNames,
                tint: Weave.codex,
                selected: agentFilter == "codex",
                help: "Codex"
            ) { agentFilter = "codex" }
            AgentRailButton(
                agent: "dsh",
                name: "DeepSeek Harness",
                compact: !showsNames,
                tint: Weave.harness,
                selected: agentFilter == "dsh",
                help: "DeepSeek Harness"
            ) { agentFilter = "dsh" }
            AgentRailButton(
                agent: "cursor",
                name: "Cursor",
                compact: !showsNames,
                tint: Weave.cursor,
                selected: agentFilter == "cursor",
                help: "Cursor"
            ) { agentFilter = "cursor" }
            Spacer(minLength: 0)
            Rectangle()
                .fill(Weave.line)
                .frame(height: 1)
                .padding(.horizontal, showsNames ? 2 : 6)
                .padding(.bottom, 6)
            refreshAction
            collapseAction
        }
        .padding(.horizontal, showsNames ? 8 : 6)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: showsNames ? 176 : 48)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { Rectangle().fill(Weave.line).frame(width: 1) }
    }

    private var refreshAction: some View {
        Button {
            Task { await model.refresh(manual: true) }
        } label: {
            HStack(spacing: 6) {
                if model.isManualScanning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                if showsNames {
                    Text("handoff.refresh", bundle: .module)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(model.isManualScanning ? Weave.muted : (isHoveringRefresh ? Weave.thread : Weave.ink))
            .padding(.horizontal, showsNames ? 7 : 0)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: showsNames ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHoveringRefresh && !model.isManualScanning ? Weave.card : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHoveringRefresh = $0 }
        .disabled(model.isManualScanning)
        .help(Text("handoff.refresh", bundle: .module))
        .accessibilityLabel(Text("handoff.refresh", bundle: .module))
    }

    private var collapseAction: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { showsNames.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsNames ? "chevron.left" : "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 16, height: 16)
                if showsNames {
                    Text("handoff.agent.rail.collapse", bundle: .module)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(isHoveringCollapse ? Weave.thread : Weave.muted)
            .padding(.horizontal, showsNames ? 7 : 0)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: showsNames ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHoveringCollapse ? Weave.card : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHoveringCollapse = $0 }
        .help(Text(showsNames ? "handoff.agent.rail.collapse" : "handoff.agent.rail.expand", bundle: .module))
        .accessibilityLabel(Text(showsNames ? "handoff.agent.rail.collapse" : "handoff.agent.rail.expand", bundle: .module))
    }
}

private struct AgentRailButton: View {
    var symbol: String? = nil
    var agent: String? = nil
    let name: String
    var compact = false
    let tint: Color
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                mark
                if !compact {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(selected ? tint : Weave.ink)
            .padding(.horizontal, compact ? 0 : 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(help))
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var mark: some View {
        if let agent {
            AgentMark(agent: agent, size: 18)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
        }
    }

    private var background: Color {
        if selected { return tint.opacity(0.16) }
        return hovering ? Weave.card.opacity(0.95) : Weave.card
    }

    private var border: Color {
        if selected { return tint.opacity(0.55) }
        return hovering ? Weave.muted.opacity(0.35) : Weave.line
    }
}

private struct AppTabButton: View {
    let tab: MainTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Weave.thread : Weave.muted)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Weave.thread.opacity(0.16) : (hovering ? Weave.card : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Weave.thread.opacity(0.55) : (hovering ? Weave.line : Color.clear), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(tab.title))
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
