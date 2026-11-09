import Foundation

/// Top-level destinations in the narrow rail. Add a case here (plus its content view)
/// and the rail will add the corresponding tab automatically.
enum MainTab: String, CaseIterable, Identifiable {
    case sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: String(localized: "tab.sessions", bundle: .module)
        }
    }

    var icon: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        }
    }
}
