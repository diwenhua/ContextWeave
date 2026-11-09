import SwiftUI
import AppKit
import ContextWeaveCore

// MARK: - Tool activity grouping

struct ToolActivity: Identifiable {
    let id: String
    var name: String
    var callID: String?
    var input: String?
    var output: String?
    var didFinish: Bool
    var timestampMilliseconds: Int64?
    var resultTimestampMilliseconds: Int64?

    var isFailed: Bool {
        guard let output else { return false }
        let head = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("error")
            || head.hasPrefix("failed")
            || head.hasPrefix("exception")
            || head.contains("traceback (most recent call last)")
            || head.contains("\"success\": false")
            || head.contains("exit code: 1")
    }

    var preview: String? {
        if let input, !input.isEmpty {
            if let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] {
                for key in ["command", "cmd", "query", "path", "file_path", "pattern", "description"] {
                    if let value = object[key] as? String, !value.isEmpty { return String(value.prefix(160)) }
                    if let value = object[key] as? [String], !value.isEmpty { return String(value.joined(separator: " ").prefix(160)) }
                }
            }
            if let line = input.split(separator: "\n", maxSplits: 1).first {
                return String(line.prefix(160))
            }
        }
        if let output, !output.isEmpty, let line = output.split(separator: "\n", maxSplits: 1).first {
            return String(line.prefix(160))
        }
        return nil
    }

    var durationMilliseconds: Int64? {
        guard let start = timestampMilliseconds, let end = resultTimestampMilliseconds, end > start else { return nil }
        return end - start
    }
}

enum TranscriptEntry: Identifiable {
    case message(SessionMessage)
    case tool(ToolActivity)

    var id: String {
        switch self {
        case .message(let message): "message:\(message.id)"
        case .tool(let activity): "tool:\(activity.id)"
        }
    }
}

enum TranscriptBuilder {
    static func entries(from messages: [SessionMessage]) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var pending: [Int] = []

        for message in messages {
            guard message.role == .tool, let parsed = ToolMessageParser.parse(message.content) else {
                entries.append(.message(message))
                continue
            }

            switch parsed.kind {
            case .call:
                entries.append(.tool(ToolActivity(
                    id: message.id,
                    name: parsed.name ?? String(localized: "handoff.role.tool", bundle: .module),
                    callID: parsed.callID,
                    input: parsed.input,
                    output: nil,
                    didFinish: false,
                    timestampMilliseconds: message.timestampMilliseconds,
                    resultTimestampMilliseconds: nil
                )))
                pending.append(entries.count - 1)

            case .result:
                let index = pending.last { candidate in
                    guard case .tool(let activity) = entries[candidate] else { return false }
                    guard activity.output == nil else { return false }
                    if let callID = parsed.callID, let pendingID = activity.callID { return callID == pendingID }
                    return true
                }
                if let index, case .tool(var activity) = entries[index] {
                    activity.output = parsed.output
                    activity.didFinish = true
                    activity.resultTimestampMilliseconds = message.timestampMilliseconds
                    entries[index] = .tool(activity)
                    pending.removeAll { $0 == index }
                } else {
                    entries.append(.tool(ToolActivity(
                        id: message.id,
                        name: parsed.name ?? String(localized: "handoff.role.tool", bundle: .module),
                        callID: parsed.callID,
                        input: nil,
                        output: parsed.output,
                        didFinish: true,
                        timestampMilliseconds: message.timestampMilliseconds,
                        resultTimestampMilliseconds: message.timestampMilliseconds
                    )))
                }

            case .combined, .unknown:
                entries.append(.tool(ToolActivity(
                    id: message.id,
                    name: parsed.name ?? String(localized: "handoff.role.tool", bundle: .module),
                    callID: parsed.callID,
                    input: parsed.input,
                    output: parsed.output,
                    didFinish: parsed.output != nil,
                    timestampMilliseconds: message.timestampMilliseconds,
                    resultTimestampMilliseconds: parsed.output == nil ? nil : message.timestampMilliseconds
                )))
            }
        }
        return entries
    }
}

private enum ToolMessageParser {
    enum Kind { case call, result, combined, unknown }
    struct Parsed {
        let kind: Kind
        let name: String?
        let callID: String?
        let input: String?
        let output: String?
    }

    static func parse(_ content: String) -> Parsed? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first.map(String.init) else { return nil }
        let first = firstLine.trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)

        if first.hasPrefix("Call ") {
            let header = headerParts(first, prefix: "Call ")
            return Parsed(kind: .call, name: header.name, callID: header.callID, input: rest.isEmpty ? nil : rest, output: nil)
        }
        if first.hasPrefix("Result") {
            let header = headerParts(first, prefix: "Result")
            return Parsed(kind: .result, name: nil, callID: header.callID, input: nil, output: rest.isEmpty ? nil : rest)
        }
        if first.hasPrefix("Tool: ") {
            let name = String(first.dropFirst("Tool: ".count)).trimmingCharacters(in: .whitespaces)
            var input = rest
            var output: String?
            if let resultRange = rest.range(of: "\nResult:") ?? rest.range(of: "Result:") {
                let before = String(rest[..<resultRange.lowerBound])
                output = String(rest[resultRange.upperBound...]).trimmingCharacters(in: .newlines)
                input = before
            }
            input = input
                .replacingOccurrences(of: "Arguments:", with: "")
                .trimmingCharacters(in: .newlines)
                .trimmingCharacters(in: .whitespaces)
            return Parsed(kind: .combined, name: name, callID: nil, input: input.isEmpty ? nil : input, output: output?.isEmpty == true ? nil : output)
        }

        let name = first.isEmpty ? nil : String(first.prefix(80))
        return Parsed(kind: .unknown, name: name, callID: nil, input: rest.isEmpty ? content : rest, output: nil)
    }

    private static func headerParts(_ line: String, prefix: String) -> (name: String?, callID: String?) {
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(":") { value.removeLast() }
        var callID: String?
        if let open = value.lastIndex(of: "["), value.hasSuffix("]") {
            callID = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
            value = String(value[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return (value.isEmpty ? nil : value, callID)
    }
}

// MARK: - Messages

struct MessageCard: View {
    let message: SessionMessage
    let agent: String

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(roleTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Weave.thread)
                        MessageTime(milliseconds: message.timestampMilliseconds)
                    }
                    MessageBody(text: message.content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Weave.thread.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Weave.thread.opacity(0.18))
                        )
                }
                ZStack {
                    Circle().fill(Weave.thread.opacity(0.14))
                    Image(systemName: "person.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Weave.thread)
                }
                .frame(width: 26, height: 26)
            }

        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: agent, size: 22)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(roleTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Weave.agent(agent))
                        MessageTime(milliseconds: message.timestampMilliseconds)
                        Spacer(minLength: 0)
                    }
                    MessageBody(text: message.content)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Weave.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Weave.agent(agent).opacity(0.22))
                )
            }

        case .system:
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    Text(message.content)
                        .font(.caption)
                        .foregroundStyle(Weave.muted)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    MessageTime(milliseconds: message.timestampMilliseconds)
                }
                Spacer(minLength: 0)
            }

        case .tool:
            MessageBody(text: message.content)
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user: String(localized: "handoff.role.user", bundle: .module)
        case .assistant: String(localized: "handoff.role.assistant", bundle: .module)
        case .tool: String(localized: "handoff.role.tool", bundle: .module)
        case .system: String(localized: "handoff.role.system", bundle: .module)
        }
    }
}

private struct MessageTime: View {
    let milliseconds: Int64?

    var body: some View {
        if let milliseconds, milliseconds > 0 {
            Text(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000).formatted(date: .omitted, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Weave.muted)
        }
    }
}

// MARK: - Tool card

struct ToolCallCard: View {
    let activity: ToolActivity
    let sessionActive: Bool
    @State private var isExpanded = false

    private enum Status { case running, completed, failed, pending }

    private var status: Status {
        if activity.didFinish {
            return activity.isFailed ? .failed : .completed
        }
        return sessionActive ? .running : .pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .help(Text(isExpanded ? "handoff.tool.collapse" : "handoff.tool.expand", bundle: .module))
            .accessibilityLabel(Text(isExpanded ? "handoff.tool.collapse" : "handoff.tool.expand", bundle: .module))

            if isExpanded {
                Divider().overlay(Weave.line).padding(.vertical, 10)
                details
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Weave.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Weave.line))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Weave.harness.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Weave.harness)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(activity.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    statusPill
                }
                if let preview = activity.preview {
                    Text(preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Weave.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let duration = durationText {
                Text(duration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Weave.muted)
            }
            MessageTime(milliseconds: activity.timestampMilliseconds)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Weave.muted)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let input = activity.input, !input.isEmpty {
                section(title: String(localized: "handoff.tool.input", bundle: .module), text: input)
            }
            if let output = activity.output, !output.isEmpty {
                section(title: String(localized: "handoff.tool.output", bundle: .module), text: output)
            } else if status == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("handoff.tool.waiting", bundle: .module).font(.caption).foregroundStyle(Weave.muted)
                }
            } else {
                Text("handoff.tool.noOutput", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(Weave.muted)
            }
        }
    }

    private func section(title: String, text: String) -> some View {
        let display = prettyText(text)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Weave.muted)
                Spacer(minLength: 0)
                CopyButton(text: display)
            }
            ScrollView {
                Text(display)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(maxHeight: 240)
            .background(Weave.canvas.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func prettyText(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(statusTitle).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var statusTitle: String {
        switch status {
        case .running: String(localized: "handoff.tool.running", bundle: .module)
        case .completed: String(localized: "handoff.tool.completed", bundle: .module)
        case .failed: String(localized: "handoff.tool.failed", bundle: .module)
        case .pending: String(localized: "handoff.tool.pending", bundle: .module)
        }
    }

    private var statusColor: Color {
        switch status {
        case .running: Weave.thread
        case .completed: .green
        case .failed: .red
        case .pending: Weave.muted
        }
    }

    private var durationText: String? {
        guard let milliseconds = activity.durationMilliseconds else { return nil }
        let seconds = Double(milliseconds) / 1000
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%.0fs", seconds)
    }

    private var icon: String {
        let name = activity.name.lowercased()
        if name.contains("exec") || name.contains("shell") || name.contains("bash") || name.contains("terminal") || name.contains("command") {
            return "terminal"
        }
        if name.contains("read") || name.contains("grep") || name.contains("search") || name.contains("find") || name.contains("glob") {
            return "doc.text.magnifyingglass"
        }
        if name.contains("write") || name.contains("edit") || name.contains("patch") || name.contains("apply") {
            return "pencil.line"
        }
        if name.contains("web") || name.contains("fetch") || name.contains("http") {
            return "globe"
        }
        if name.contains("todo") || name.contains("plan") || name.contains("task") {
            return "checklist"
        }
        return "wrench.and.screwdriver"
    }
}

// MARK: - Message body and code blocks

private struct MessageBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MessageMarkup.segments(text)) { segment in
                if let language = segment.language {
                    CodeBlock(code: segment.text, language: language)
                } else if let attributed = try? AttributedString(
                    markdown: segment.text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(segment.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct MessageSegment: Identifiable {
    let id: Int
    let text: String
    let language: String?
}

private enum MessageMarkup {
    static func segments(_ text: String) -> [MessageSegment] {
        var output: [MessageSegment] = []
        var buffer: [String] = []
        var inCode = false
        var language = ""

        func flush() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            buffer.removeAll(keepingCapacity: true)
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            output.append(MessageSegment(id: output.count, text: joined, language: inCode ? (language.isEmpty ? "code" : language) : nil))
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                flush()
                if inCode {
                    inCode = false
                    language = ""
                } else {
                    inCode = true
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else {
                buffer.append(line)
            }
        }
        flush()
        if output.isEmpty {
            output.append(MessageSegment(id: 0, text: text, language: nil))
        }
        return output
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Weave.muted)
                Spacer(minLength: 0)
                CopyButton(text: code)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().overlay(Weave.line)
            ScrollView {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 320)
        }
        .background(Weave.canvas.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Weave.line))
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Weave.muted)
        .help(Text(copied ? "handoff.copied" : "handoff.code.copy", bundle: .module))
        .accessibilityLabel(Text(copied ? "handoff.copied" : "handoff.code.copy", bundle: .module))
    }
}
