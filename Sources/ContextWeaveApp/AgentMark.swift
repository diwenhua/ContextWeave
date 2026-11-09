import SwiftUI
import AppKit

/// Reads installed agent icons at runtime; third-party artwork is not bundled.
@MainActor
struct AgentMark: View {
    let agent: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Weave.agent(agent))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var artwork: NSImage? {
        AgentArtwork.image(for: agent)
    }
}

@MainActor
private enum AgentArtwork {
    private static var cache: [String: NSImage] = [:]

    static func image(for agent: String) -> NSImage? {
        if let cached = cache[agent] { return cached }
        let path: String
        switch agent {
        case "dsh": path = "/Applications/DeepSeek Harness.app/Contents/Resources/icon.png"
        case "cursor": path = "/Applications/Cursor.app/Contents/Resources/Cursor.icns"
        case "codex": path = "/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png"
        default: return nil
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[agent] = image
        return image
    }
}
