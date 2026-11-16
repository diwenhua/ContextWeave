import SwiftUI
import ContextWeaveCore

struct MemoryPage: View {
    @EnvironmentObject private var model: HandoffModel
    let projectLabel: (String?) -> String
    let openSession: (SessionID) -> Void
    @State private var selection: MemorySelection?
    @State private var collapsedProjects: Set<String> = []
    @State private var search = ""
    @State private var showsRejected = false
    @State private var kind: String?

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var groups: [MemoryProjectGroup] {
        let buckets = Dictionary(grouping: model.sessions, by: groupKey)
        return buckets.map { key, sessions in
            let ordered = sessions.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return MemoryProjectGroup(id: key, label: groupLabel(ordered[0]), sessions: ordered)
        }
        .sorted { lhs, rhs in
            let left = lhs.sessions.map(\.lastActivity).max() ?? 0
            let right = rhs.sessions.map(\.lastActivity).max() ?? 0
            if left != right { return left > right }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private var visibleGroups: [MemoryProjectGroup] {
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.label.localizedCaseInsensitiveContains(query) { return group }
            let sessions = group.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
            guard !sessions.isEmpty else { return nil }
            return MemoryProjectGroup(id: group.id, label: group.label, sessions: sessions)
        }
    }

    private var active: MemorySelection {
        selection ?? .global
    }

    private var scopedMemories: [ProjectMemory] {
        model.memories.filter(inScope)
    }

    private var currentMemories: [ProjectMemory] {
        scopedMemories
            .filter { showsRejected || $0.status != "rejected" }
            .filter { kind == nil || $0.kind == kind }
            .sorted(by: memorySort)
    }

    private var rejectedCount: Int {
        scopedMemories.filter { $0.status == "rejected" && (kind == nil || $0.kind == kind) }.count
    }

    private func inScope(_ memory: ProjectMemory) -> Bool {
        switch active {
        case .global:
            return memory.scope == "global"
        case .project(let id):
            return memory.scope == "project" && memory.stableProjectID == id
        case .session(let id):
            return memory.scope == "session" && memory.agent == id.agent && memory.externalID == id.externalID
        }
    }

    private func kindCount(_ value: String?) -> Int {
        scopedMemories.filter { $0.status != "rejected" && (value == nil || $0.kind == value) }.count
    }

    var body: some View {
        HSplitView {
            rail
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Weave.canvas)
        .task { model.start() }
        .onAppear { selectDefaultIfNeeded() }
        .onChange(of: model.sessions.map(\.id)) { _ in selectDefaultIfNeeded() }
    }

    private var kindTabs: some View {
        HStack(spacing: 8) {
            kindTab(nil, title: String(localized: "memory.kind.all", bundle: .module))
            kindTab("summary", title: String(localized: "handoff.memory.summary", bundle: .module))
            kindTab("decision", title: String(localized: "handoff.memory.decision", bundle: .module))
            kindTab("preference", title: String(localized: "handoff.memory.preference", bundle: .module))
            Spacer(minLength: 0)
        }
    }

    private func kindTab(_ value: String?, title: String) -> some View {
        let selected = kind == value
        return Button {
            kind = value
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(kindCount(value))")
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(selected ? Weave.thread : Weave.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Weave.thread.opacity(0.14) : Weave.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Weave.thread.opacity(0.5) : Weave.line)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Weave.muted)
                    TextField(String(localized: "memory.nav.search", bundle: .module), text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Weave.card))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Weave.line))
                if model.isManualScanning {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24)
                } else {
                    Button {
                        Task { await model.refresh(manual: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Weave.muted)
                    .help(Text("handoff.refresh", bundle: .module))
                }
            }
            .padding(12)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text("memory.ruleMode", bundle: .module)
            }
            .font(.caption).foregroundStyle(Weave.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    globalRow
                    if visibleGroups.isEmpty {
                        Text("memory.nav.empty", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(Weave.muted)
                            .padding(.horizontal, 8)
                    }
                    ForEach(visibleGroups) { group in
                        projectBlock(group)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 380)
        .background(Weave.sidebar)
    }

    private var globalRow: some View {
        let selected = active == .global
        let count = model.memories.filter { $0.scope == "global" && $0.status != "rejected" && (kind == nil || $0.kind == kind) }.count
        return Button {
            selection = .global
            showsRejected = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Weave.thread)
                    .frame(width: 16)
                Text("memory.scope.global", bundle: .module)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Weave.thread.opacity(0.14) : Weave.card.opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Weave.thread.opacity(0.55) : Weave.line, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func projectBlock(_ group: MemoryProjectGroup) -> some View {
        let expanded = !collapsedProjects.contains(group.id)
        let projectSelected = active == .project(group.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if expanded { collapsedProjects.insert(group.id) } else { collapsedProjects.remove(group.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Weave.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("memory.project.toggle", bundle: .module))
                Button {
                    selection = .project(group.id)
                    showsRejected = false
                    collapsedProjects.remove(group.id)
                } label: {
                    MemoryProjectRow(label: group.label, count: projectMemoryCount(group.id), active: projectSelected)
                }
                .buttonStyle(.plain)
                .help(Text("memory.project.open", bundle: .module))
                .accessibilityAddTraits(projectSelected ? .isSelected : [])
            }
            if expanded {
                ForEach(group.sessions) { item in
                    let selected = active == .session(item.id)
                    Button {
                        selection = .session(item.id)
                        showsRejected = false
                    } label: {
                        MemorySessionRow(item: item, count: sessionMemoryCount(item), active: selected)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 28)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Weave.card.opacity(0.28)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Weave.line, lineWidth: 1)
        )
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            kindTabs
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Weave.card.opacity(0.55))
                .overlay(alignment: .bottom) { Rectangle().fill(Weave.line).frame(height: 1) }
            detailHeader
            if currentMemories.isEmpty && rejectedCount == 0 {
                detailEmpty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(currentMemories, id: \.id) { memory in
                            MemoryEntry(
                                memory: memory,
                                showsAgent: showsSource,
                                sourceTitle: showsSource ? sourceTitle(memory) : nil,
                                onOpenSource: openSource(memory)
                            )
                        }
                        if rejectedCount > 0 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) { showsRejected.toggle() }
                            } label: {
                                Text(rejectedLabel(showsRejected, count: rejectedCount))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Weave.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .background(Weave.canvas)
    }

    private var showsSource: Bool {
        if case .session = active { return false }
        return true
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch active {
            case .global:
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundStyle(Weave.thread)
                    Text("memory.scope.global", bundle: .module)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Weave.thread)
                    Spacer(minLength: 8)
                    countLabel
                }
                Text("memory.global.title", bundle: .module)
                    .font(.system(size: 22, weight: .semibold))
                Text("memory.global.subtitle", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(Weave.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .project(let id):
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(Weave.thread)
                    Text("memory.scope.project", bundle: .module)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Weave.thread)
                    Spacer(minLength: 8)
                    countLabel
                }
                Text(groups.first { $0.id == id }?.label ?? projectLabel(id.isEmpty ? nil : id))
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(2)
                Text("memory.project.subtitle", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(Weave.muted)
            case .session(let id):
                HStack(spacing: 8) {
                    Text("memory.scope.session", bundle: .module)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Weave.thread)
                    Spacer(minLength: 8)
                    AgentPill(agent: id.agent, compact: true)
                    Button {
                        openSession(id)
                    } label: {
                        Text("memory.openSession", bundle: .module)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text(sessionTitle(id))
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(2)
                Text(projectLabel(model.sessions.first { $0.id == id }?.stableProjectID))
                    .font(.caption)
                    .foregroundStyle(Weave.muted)
                    .lineLimit(1)
                Text("memory.semantic.privacy", bundle: .module)
                    .font(.caption).foregroundStyle(Weave.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(String(localized: "memory.semantic.run", bundle: .module)) { model.extractMemory(id) }
                        .disabled(model.extractingMemory != nil)
                    if model.extractingMemory == id { ProgressView().controlSize(.small) }
                    if let message = model.memoryExtractionMessage { Text(message).font(.caption).foregroundStyle(Weave.muted) }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Weave.card.opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(Weave.line).frame(height: 1) }
    }

    private var countLabel: some View {
        Text(String(format: String(localized: "memory.count", bundle: .module), currentMemories.count))
            .font(.caption.weight(.medium))
            .foregroundStyle(Weave.muted)
    }

    private var detailEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Weave.muted)
            Text(emptyTitle, bundle: .module)
                .font(.title3.weight(.semibold))
            Text(emptyBody, bundle: .module)
                .font(.callout)
                .foregroundStyle(Weave.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch active {
        case .global: "globe"
        case .project: "folder"
        case .session: "bubble.left.and.bubble.right"
        }
    }

    private var kindFiltersCurrentScope: Bool {
        guard kind != nil else { return false }
        return scopedMemories.contains { $0.status != "rejected" }
    }

    private var emptyTitle: LocalizedStringKey {
        if kindFiltersCurrentScope { return "memory.emptyFilter" }
        switch active {
        case .global: return "memory.global.emptyTitle"
        case .project: return "memory.project.emptyTitle"
        case .session: return "memory.session.emptyTitle"
        }
    }

    private var emptyBody: LocalizedStringKey {
        if kindFiltersCurrentScope { return "memory.emptyFilterBody" }
        switch active {
        case .global: return "memory.global.emptyBody"
        case .project: return "memory.project.emptyBody"
        case .session: return "memory.session.emptyBody"
        }
    }

    private func selectDefaultIfNeeded() {
        switch selection {
        case .session(let id):
            if model.sessions.contains(where: { $0.id == id }) { return }
        case .project(let id):
            if groups.contains(where: { $0.id == id }) { return }
        case .global:
            return
        case nil:
            break
        }
        if let latest = model.sessions.max(by: { $0.lastActivity < $1.lastActivity }) {
            selection = .session(latest.id)
            collapsedProjects.remove(groupKey(latest))
        } else {
            selection = .global
        }
    }

    private func groupKey(_ item: SessionSummary) -> String {
        if let id = item.stableProjectID, !id.isEmpty { return id }
        if let path = item.projectID, !path.isEmpty { return path }
        return ""
    }

    private func groupLabel(_ item: SessionSummary) -> String {
        if let id = item.stableProjectID, !id.isEmpty { return projectLabel(id) }
        if let path = item.projectID, !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
        return String(localized: "handoff.noProject", bundle: .module)
    }

    private func projectMemoryCount(_ id: String) -> Int {
        model.memories.filter {
            $0.scope == "project" && $0.stableProjectID == id && $0.status != "rejected" && (kind == nil || $0.kind == kind)
        }.count
    }

    private func sessionMemoryCount(_ item: SessionSummary) -> Int {
        model.memories.filter {
            $0.scope == "session" && $0.agent == item.id.agent && $0.externalID == item.id.externalID && $0.status != "rejected" && (kind == nil || $0.kind == kind)
        }.count
    }

    private func sessionTitle(_ id: SessionID) -> String {
        let match = (model.sessions + model.archivedSessions).first { $0.id == id }
        let title = match?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? id.externalID : title
    }

    private func sourceTitle(_ memory: ProjectMemory) -> String {
        memorySourceTitle(memory, sessions: model.sessions + model.archivedSessions)
    }

    private func sessionID(of memory: ProjectMemory) -> SessionID? {
        try? SessionID(agent: memory.agent, externalID: memory.externalID)
    }

    private func openSource(_ memory: ProjectMemory) -> (() -> Void)? {
        guard showsSource, let id = sessionID(of: memory), model.sessions.contains(where: { $0.id == id }) else { return nil }
        return { openSession(id) }
    }
}

private enum MemorySelection: Hashable {
    case global
    case project(String)
    case session(SessionID)
}

private struct MemoryProjectGroup: Identifiable {
    let id: String
    let label: String
    let sessions: [SessionSummary]
}

private struct MemoryProjectRow: View {
    let label: String
    let count: Int
    let active: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Weave.thread.opacity(active || hovering ? 0.18 : 0.1))
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Weave.thread)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Weave.ink)
                    .lineLimit(1)
                Text("memory.scope.project", bundle: .module)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Weave.thread)
            }
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Weave.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Weave.canvas.opacity(0.72)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? Weave.thread.opacity(0.14) : (hovering ? Weave.card : Weave.canvas.opacity(0.72)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Weave.thread.opacity(0.6) : (hovering ? Weave.thread.opacity(0.35) : Weave.line), lineWidth: active ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }
}

private struct MemorySessionRow: View {
    let item: SessionSummary
    let count: Int
    let active: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Weave.agent(item.id.agent) : Weave.muted)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title.isEmpty ? item.id.externalID : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Weave.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Weave.agent(item.id.agent))
                }
                HStack(spacing: 8) {
                    Text("memory.scope.session", bundle: .module)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Weave.muted)
                    AgentPill(agent: item.id.agent, compact: true)
                    Spacer(minLength: 8)
                    if item.lastActivity > 0 {
                        Text(Date(timeIntervalSince1970: TimeInterval(item.lastActivity) / 1000).formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(Weave.muted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? Weave.card : (hovering ? Weave.card.opacity(0.8) : Weave.canvas.opacity(0.4)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Weave.agent(item.id.agent).opacity(0.7) : Weave.line, lineWidth: active ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }
}

private struct MemoryEntry: View {
    @EnvironmentObject private var model: HandoffModel
    let memory: ProjectMemory
    var showsAgent = true
    var sourceTitle: String?
    var onOpenSource: (() -> Void)?

    private var tint: Color { Weave.agent(memory.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(memoryKindTitle(memory.kind))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Weave.thread)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Weave.thread.opacity(0.12)))
                Text(String(localized: String.LocalizationValue("memory.status.\(memory.status)"), bundle: .module))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Weave.muted)
                Spacer(minLength: 4)
                if showsAgent {
                    AgentPill(agent: memory.agent, compact: true)
                }
            }
            Text(memory.content)
                .font(.system(size: 14))
                .foregroundStyle(Weave.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let sourceTitle {
                    Text(sourceTitle)
                        .lineLimit(1)
                    if let onOpenSource {
                        Button(action: onOpenSource) {
                            Text("memory.openSession", bundle: .module)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tint)
                    }
                }
                Spacer(minLength: 8)
                if memory.updatedAt > 0 {
                    Text(Date(timeIntervalSince1970: TimeInterval(memory.updatedAt) / 1000).formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption)
            .foregroundStyle(Weave.muted)
            if memory.status != "checkpoint" {
                HStack(spacing: 8) {
                    if memory.status != "confirmed" {
                        Button(String(localized: "memory.confirm", bundle: .module)) { model.reviewMemory(memory, status: "confirmed") }
                    }
                    if memory.status != "rejected" {
                        Button(String(localized: "memory.reject", bundle: .module)) { model.reviewMemory(memory, status: "rejected") }
                    }
                    if memory.status != "candidate" {
                        Button(String(localized: "memory.reset", bundle: .module)) { model.reviewMemory(memory, status: "candidate") }
                    }
                    Menu {
                        ForEach(["global", "project", "session"], id: \.self) { destination in
                            Button(String(localized: String.LocalizationValue("memory.scope.\(destination)"), bundle: .module)) {
                                model.moveMemory(memory, scope: destination)
                            }
                            .disabled(memory.scope == destination)
                        }
                    } label: {
                        Text("memory.move", bundle: .module)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Weave.card))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.7))
                .frame(width: 3)
                .padding(.vertical, 12)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Weave.line, lineWidth: 1))
    }
}

private func rejectedLabel(_ shown: Bool, count: Int) -> String {
    let key: String.LocalizationValue = shown ? "memory.rejected.hide" : "memory.rejected.show"
    return String(format: String(localized: key, bundle: .module), count)
}

private func memoryKindTitle(_ kind: String) -> String {
    switch kind {
    case "summary": String(localized: "handoff.memory.summary", bundle: .module)
    case "decision": String(localized: "handoff.memory.decision", bundle: .module)
    default: String(localized: "handoff.memory.preference", bundle: .module)
    }
}

private func memorySort(_ lhs: ProjectMemory, _ rhs: ProjectMemory) -> Bool {
    func rank(_ kind: String) -> Int {
        switch kind {
        case "summary": 0
        case "decision": 1
        default: 2
        }
    }
    if rank(lhs.kind) != rank(rhs.kind) { return rank(lhs.kind) < rank(rhs.kind) }
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return lhs.id < rhs.id
}

private func memorySourceTitle(_ memory: ProjectMemory, sessions: [SessionSummary]) -> String {
    let match = sessions.first { $0.source.id.agent == memory.agent && $0.source.id.externalID == memory.externalID }
    let title = match?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? memory.externalID : title
}
