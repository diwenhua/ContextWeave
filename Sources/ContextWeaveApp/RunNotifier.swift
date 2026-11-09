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
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.post(title: title, subtitle: subtitle, body: body, session: session)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    Self.post(title: title, subtitle: subtitle, body: body, session: session)
                }
            default:
                break
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
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
