import Foundation

/// Handles CSS sanitization within HTML content
struct HTMLCSSSanitizer {
    private static let cssSanitizationRules: [(pattern: String, replacement: String)] = [
        ("javascript:", ""),                           // Remove javascript: in CSS
        ("expression\\s*\\([^)]*\\)", ""),             // Remove expression() (IE specific)
        ("@import[^;]*;", ""),                         // Remove @import
        ("behavior\\s*:[^;]*;", ""),                   // Remove behavior property (IE specific)
        ("-moz-binding\\s*:[^;]*;", "")                // Remove -moz-binding (Firefox specific)
    ]

    /// Sanitizes inline style attributes in HTML
    func sanitizeInlineStyles(_ html: String) -> String {
        let stylePattern = "style\\s*=\\s*[\"']([^\"']*)[\"']"
        let regex = try? NSRegularExpression(pattern: stylePattern, options: .caseInsensitive)
        let matches = regex?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []

        var result = html
        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let styleContent = String(result[range])
                let sanitizedStyle = sanitizeCSS(styleContent)
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: "style=\"\(sanitizedStyle)\"")
            }
        }

        return result
    }

    /// Sanitizes CSS content
    func sanitizeCSS(_ css: String) -> String {
        RegexSanitizer.applyRules(to: css, rules: Self.cssSanitizationRules)
    }
}
