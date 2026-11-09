import Foundation

/// Best-effort masking for compact metadata derived from user-authored text.
/// Raw source records remain unchanged; output boundaries use PathRedactor.
public enum MetadataPrivacy {
    public static func redactPaths(_ text: String) -> String {
        PathRedactor().redact(text)
    }
}
