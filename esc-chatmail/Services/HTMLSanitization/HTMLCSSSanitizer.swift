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

    // Cached compiled regex patterns for performance
    // Need separate patterns for double-quoted and single-quoted attributes
    // to correctly handle quotes inside the value (e.g., font-family: 'Arial')
    private static let styleRegexDoubleQuote: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "style\\s*=\\s*\"([^\"]*)\"",
            options: .caseInsensitive
        )
    }()

    private static let styleRegexSingleQuote: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "style\\s*=\\s*'([^']*)'",
            options: .caseInsensitive
        )
    }()

    /// Sanitizes inline style attributes in HTML
    func sanitizeInlineStyles(_ html: String) -> String {
        var result = html

        // Process double-quoted style attributes: style="..."
        if let regex = Self.styleRegexDoubleQuote {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: result) {
                    let styleContent = String(result[range])
                    let sanitizedStyle = sanitizeCSS(styleContent)
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: "style=\"\(sanitizedStyle)\"")
                }
            }
        }

        // Process single-quoted style attributes: style='...'
        if let regex = Self.styleRegexSingleQuote {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: result) {
                    let styleContent = String(result[range])
                    let sanitizedStyle = sanitizeCSS(styleContent)
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: "style=\"\(sanitizedStyle)\"")
                }
            }
        }

        return result
    }

    /// Sanitizes CSS content
    func sanitizeCSS(_ css: String) -> String {
        RegexSanitizer.applyRules(to: css, rules: Self.cssSanitizationRules)
    }
}
