import SwiftUI
import AppKit

@main
struct ContextWeaveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var updates: UpdateController
    @StateObject private var settings: SettingsStore
    @StateObject private var model: HandoffModel

    init() {
        let settings = SettingsStore()
        NSApplication.shared.appearance = settings.settings.appearance.nsAppearance
        _updates = StateObject(wrappedValue: UpdateController())
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: HandoffModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup("ContextWeave") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(model)
                .contextWeaveAppearance(settings.settings.appearance)
                .frame(minWidth: 1040, idealWidth: 1280, minHeight: 680, idealHeight: 800)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(String(localized: "updates.check", bundle: .module)) {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(model)
                .environmentObject(updates)
                .contextWeaveAppearance(settings.settings.appearance)
        }
    }
}

@MainActor
enum SettingsWindow {
    /// SwiftUI's Settings scene is opened through AppKit on macOS 13, where `openSettings` is unavailable.
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

enum WindowSizing {
    private static let migratedKey = "contextweave.didApplyDefaultWindowSize"
    private static let contentSize = NSSize(width: 1280, height: 800)

    static func applyDefaultIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == "ContextWeave" && $0.canBecomeMain }) else { return }
            window.setContentSize(contentSize)
            window.center()
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
    }
}

/// SwiftPM launches and in-place development builds may have a cached generic Dock icon.
/// Set the running application's icon from its own resources after AppKit finishes launching.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        RunNotifier.shared.start()
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}
