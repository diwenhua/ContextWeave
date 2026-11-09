import SwiftUI
import AppKit
import ContextWeaveCore

extension AppearancePreference {
    /// `nil` tells SwiftUI to inherit the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// App-wide override also covers AppKit panels such as open/save panels and Sparkle windows.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Keeps both the SwiftUI presentation and the AppKit app appearance in sync.
/// Apple documents `preferredColorScheme` for presentations and `NSApp.appearance` for app-wide overrides.
@MainActor
private struct AppearanceSync: ViewModifier {
    let preference: AppearancePreference

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preference.colorScheme)
            .onAppear { apply() }
            .onChange(of: preference) { _ in apply() }
    }

    private func apply() {
        NSApp.appearance = preference.nsAppearance
    }
}

extension View {
    func contextWeaveAppearance(_ preference: AppearancePreference) -> some View {
        modifier(AppearanceSync(preference: preference))
    }
}
