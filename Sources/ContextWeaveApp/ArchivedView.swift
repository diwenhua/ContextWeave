import SwiftUI
import ContextWeaveCore

struct ArchivedSessionCard: View {
    let item: SessionSummary
    let project: String
    @State private var hovering = false

    private var tint: Color { Weave.agent(item.source.id.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentPill(agent: item.source.id.agent)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "lock")
                    Text("archive.readOnly", bundle: .appResources)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Weave.muted)
            }
            Text(item.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.caption2)
                Text(project).font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(item.messageCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
            .foregroundStyle(Weave.muted)
            HStack(spacing: 6) {
                Image(systemName: "archivebox").font(.caption2)
                Text(archivedLabel)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .font(.caption2)
            .foregroundStyle(Weave.muted)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? Weave.card : Weave.card.opacity(0.65))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(hovering ? 1 : 0.55))
                .frame(width: 3)
                .padding(.vertical, 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? tint.opacity(0.55) : Weave.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { value in
            withAnimation(.easeInOut(duration: 0.12)) { hovering = value }
        }
    }

    private var archivedLabel: String {
        let stamp = item.archivedAt ?? item.lastActivity
        let relative = Date(timeIntervalSince1970: TimeInterval(stamp) / 1000)
            .formatted(.relative(presentation: .named))
        return String(format: String(localized: "archive.archivedAt", bundle: .appResources), relative)
    }
}

struct ArchivedPreviewSheet: View {
    let summary: SessionSummary
    @EnvironmentObject private var model: HandoffModel
    @Environment(\.dismiss) private var dismiss
    @State private var session: Session?
    @State private var start = 0
    @State private var loading = true
    @State private var loadingEarlier = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Weave.line)
            if let session {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if start > 0 {
                            Button(String(localized: "handoff.earlier", bundle: .appResources)) {
                                Task { await loadEarlier() }
                            }
                            .disabled(loadingEarlier)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(TranscriptBuilder.entries(from: session.messages)) { entry in
                            switch entry {
                            case .message(let message):
                                MessageCard(message: message, agent: summary.source.id.agent)
                            case .tool(let activity):
                                ToolCallCard(activity: activity, sessionActive: false)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else if loading {
                ProgressView(String(localized: "archive.loading", bundle: .appResources))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("archive.emptySession", bundle: .appResources)
                    .font(.callout)
                    .foregroundStyle(Weave.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Weave.canvas)
        .task(id: summary.id) {
            loading = true
            let page = await model.load(summary.id)
            guard !Task.isCancelled else { return }
            session = page?.session
            start = page?.start ?? 0
            loading = false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentPill(agent: summary.source.id.agent)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                    Text("archive.readOnly", bundle: .appResources)
                    Text("·")
                    Text(String(format: String(localized: "archive.messages", bundle: .appResources), summary.messageCount))
                }
                .font(.caption2)
                .foregroundStyle(Weave.muted)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Weave.muted)
            .help(Text("archive.close", bundle: .appResources))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func loadEarlier() async {
        guard start > 0, !loadingEarlier, let current = session else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        guard let page = await model.load(summary.id, before: start) else { return }
        session = Session(
            source: current.source,
            projectID: current.projectID,
            messages: page.session.messages + current.messages,
            stableProjectID: current.stableProjectID,
            runState: current.runState
        )
        start = page.start
    }
}
