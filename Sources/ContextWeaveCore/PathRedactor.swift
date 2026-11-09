import Foundation

/// Output-only path minimization. Original captured messages and progress stay on disk.
/// Workspace-relative suffixes are retained so another agent can find project files.
public struct PathRedactor: Sendable {
    public let workspacePaths: [String]
    public init(workspacePaths: [String] = []) {
        self.workspacePaths = workspacePaths.filter { $0.hasPrefix("/") && $0 != "/" }
    }

    public func redact(_ text: String) -> String {
        var result = text
        var prefixes: Set<String> = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for original in workspacePaths {
            let path = original.hasSuffix("/") ? String(original.dropLast()) : original
            var variants = [path, URL(fileURLWithPath: path).absoluteString]
            if path.hasPrefix("/private/tmp/") { variants.append(String(path.dropFirst("/private".count))) }
            if path.hasPrefix("/private/var/") { variants.append(String(path.dropFirst("/private".count))) }
            if path.hasPrefix(home + "/") { variants.append("~" + path.dropFirst(home.count)) }
            for variant in variants {
                prefixes.insert(variant)
                prefixes.insert(variant.replacingOccurrences(of: " ", with: "\\ "))
                prefixes.insert(variant.replacingOccurrences(of: "/", with: "\\/"))
            }
        }
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: prefix)
            // Keep the suffix, but do not match a neighbouring folder or a URL component.
            let expression = #"(?<![\w/])"# + escaped + #"(?=$|[/\\]|\s|[\"'`.,;:!?，。；、）)\]}>])"#
            result = result.replacingOccurrences(of: expression, with: "[PROJECT]", options: .regularExpression)
        }
        // Mask file URLs, Windows drive/UNC paths, shell-escaped spaces, home-relative
        // and other absolute local paths. Avoid matching common API routes and web URLs.
        let patterns = [
            #"(?i)(?<=['"`])(?:file://)?(?:~?/|[a-z]:\\)(?!/)(?!(?:api|v[0-9]+|mcp|health|ready|metrics|bin|sbin|usr/bin)(?:/|\b))[^\r\n"'`<>]+(?=['"`])"#,
            #"(?<=['"`])\\/(?!\\/)(?:\\/|[^\r\n"'`])+?(?=['"`])"#,
            #"(?i)(?<![\w/\]])\\u002f(?!\\u002f)(?:\\u002f|[^\s\\"'`<>，。；、）)\]}>])+"#,
            #"(?i)\bfile:///{1,2}(?:\\ |[^\s\"'`<>，。；、）)\]}>])+"#,
            #"(?i)(?<![\w/])(?:[a-z]:\\|\\\\[^\s\\]+\\)(?:\\ |[^\s\"'`<>，。；、）)\]}>])+"#,
            #"(?<![\w/\]])(?:~?/)(?!/)(?!(?:api|v[0-9]+|mcp|health|ready|metrics|bin|sbin|usr/bin)(?:/|\b))(?:\\ |[^\s\"'`<>，。；、）)\]}>])+"#,
            #"(?<![\w/\]])\\/(?!\\/)(?:\\/|[^\s\\\"'`<>，。；、）)\]}>])+"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[LOCAL_PATH]", options: .regularExpression)
        }
        return result
    }
}
