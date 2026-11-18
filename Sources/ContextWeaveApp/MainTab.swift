import Foundation

/// Top-level destinations in the narrow rail. Add a case here (plus its content view)
/// and the rail will add the corresponding tab automatically.
enum MainTab: String, CaseIterable, Identifiable {
    case sessions
    case memory
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: String(localized: "tab.sessions", bundle: .module)
        case .memory: String(localized: "tab.memory", bundle: .module)
        case .archived: String(localized: "tab.archived", bundle: .module)
        }
    }

    var icon: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .memory: "memorychip"
        case .archived: "archivebox"
        }
    }
}
