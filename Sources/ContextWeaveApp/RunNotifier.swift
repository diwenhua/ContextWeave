import Foundation
@preconcurrency import UserNotifications
import ContextWeaveCore

/// Posts turn completion through Notification Center so the prompt follows System Settings.
final class RunNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = RunNotifier()
    var onOpen: (@Sendable (String, String) -> Void)?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(title: String, subtitle: String? = nil, body: String, session: SessionID? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let alertsEnabled = settings.alertSetting == .enabled
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                if alertsEnabled {
                    Self.post(title: title, subtitle: subtitle, body: body, session: session)
                } else {
                    Self.banner(title: title, subtitle: subtitle, body: body)
                }
            case .notDetermined:
                Self.banner(title: title, subtitle: subtitle, body: body)
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            default:
                // This local build is not a registered notification client until it is signed.
                // A banner still has to reach the user while an approval is waiting.
                Self.banner(title: title, subtitle: subtitle, body: body)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let agent = info["agent"] as? String, let externalID = info["externalID"] as? String else { return }
        onOpen?(agent, externalID)
    }

    private static func post(title: String, subtitle: String?, body: String, session: SessionID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle ?? ""
        content.body = body
        content.sound = .default
        if let session {
            content.userInfo = ["agent": session.agent, "externalID": session.externalID]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            guard error != nil else { return }
            Self.banner(title: title, subtitle: subtitle, body: body)
        }
    }

    /// Notification Center drops alerts for this ad-hoc bundle. Show the same text through the system banner.
    private static func banner(title: String, subtitle: String?, body: String) {
        let script = "display notification \(apple(body)) with title \(apple(title)) subtitle \(apple(subtitle ?? "")) sound name \"Glass\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func apple(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = collapsed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
