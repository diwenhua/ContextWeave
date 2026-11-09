import SwiftUI

@main
struct ContextWeaveApp: App {
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup("ContextWeave") {
            ContentView()
                .frame(minWidth: 680, minHeight: 440)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(String(localized: "updates.check", bundle: .module)) {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}
