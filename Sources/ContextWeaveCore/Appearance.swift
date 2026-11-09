import Foundation

/// How ContextWeave chooses its light or dark appearance.
/// `.system` follows the macOS setting; the other cases apply an app-wide override.
public enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}
