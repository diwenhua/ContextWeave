import Foundation
import os

/// Logs only fixed event names and error categories, never request arguments or file paths.
public enum MCPDiagnostics {
    private static let logger = Logger(subsystem: "local.contextweave.mcp", category: "lifecycle")

    public static func event(_ event: String, category: String) {
        // Call sites supply fixed strings only. No user-controlled request content is logged.
        logger.notice("event=\(event, privacy: .public) category=\(category, privacy: .public)")
    }

    static func category(_ error: Error) -> String {
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain && (ns.code == 1 || ns.code == 13)) ||
            (ns.domain == NSCocoaErrorDomain && (ns.code == 257 || ns.code == 513)) { return "permission" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let nested = category(underlying)
            if nested != "unavailable" { return nested }
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("permission denied") || message.contains("operation not permitted") { return "permission" }
        if message.contains("locked") || message.contains("busy") { return "database_busy" }
        if message.contains("schema") || message.contains("migration") { return "database_schema" }
        if message.contains("cannot open local session database") { return "database_open" }
        return "unavailable"
    }
}

/// One in-flight open is shared by concurrent requests. Failed opens are never cached.
actor MCPServiceProvider {
    private let open: @Sendable () async throws -> HandoffService
    private var ready: HandoffService?
    private var opening: Task<HandoffService, Error>?

    init(service: HandoffService) {
        self.ready = service
        self.open = { service }
    }

    init(configuration: CaptureConfiguration) {
        self.open = { try await Task.detached(priority: .utility) { try HandoffService(configuration: configuration) }.value }
    }

    init(open: @escaping @Sendable () async throws -> HandoffService) { self.open = open }

    func get() async throws -> HandoffService {
        if let ready { return ready }
        if let opening { return try await opening.value }
        let open = self.open
        let task = Task { () throws -> HandoffService in
            for attempt in 0..<3 {
                do {
                    let result = try await open()
                    MCPDiagnostics.event("service_ready", category: "ok")
                    return result
                } catch {
                    let category = MCPDiagnostics.category(error)
                    MCPDiagnostics.event("service_open_failed", category: category)
                    guard category == "database_busy", attempt < 2 else { throw error }
                    try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
                }
            }
            throw CaptureError.invalid("ContextWeave service unavailable")
        }
        opening = task
        do {
            let service = try await task.value
            ready = service; opening = nil
            return service
        } catch {
            opening = nil
            throw error
        }
    }
}

/// Concurrent read requests share a scan instead of starting competing scan storms.
actor MCPScanCoordinator {
    private var current: Task<CaptureReport, Never>?
    func scan(_ service: HandoffService) async -> CaptureReport {
        if let current { return await current.value }
        let task = Task { await service.scan() }
        current = task
        let result = await task.value
        current = nil
        if !result.errors.isEmpty { MCPDiagnostics.event("scan_completed_with_errors", category: "capture") }
        return result
    }
}
