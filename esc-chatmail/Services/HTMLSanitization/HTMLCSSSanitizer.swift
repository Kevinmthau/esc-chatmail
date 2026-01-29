import Foundation

/// Handles CSS sanitization within HTML content
struct HTMLCSSSanitizer {
    private static let cssSanitizationRules: [(pattern: String, replacement: String)] = [
        ("javascript:", ""),                           // Remove javascript: in CSS
        ("vbscript:", ""),                             // Remove vbscript: in CSS
        ("expression\\s*\\([^)]*\\)", ""),             // Remove expression() (IE specific)
        ("@import[^;]*;", ""),                         // Remove @import
        ("behavior\\s*:[^;]*;", ""),                   // Remove behavior property (IE specific)
        ("-moz-binding\\s*:[^;]*;", ""),               // Remove -moz-binding (Firefox specific)
        ("-webkit-binding\\s*:[^;]*;", ""),            // Remove -webkit-binding
        ("url\\s*\\([^)]*javascript:[^)]*\\)", ""),    // Remove url() with javascript:
        ("url\\s*\\([^)]*vbscript:[^)]*\\)", ""),      // Remove url() with vbscript:
        ("url\\s*\\([^)]*data:text/html[^)]*\\)", "") // Remove url() with data:text/html
    ]

    // Cached compiled regex patterns for performance
    // Need separate patterns for double-quoted and single-quoted attributes
    // to correctly handle quotes inside the value (e.g., font-family: 'Arial')
    // swiftlint:disable:next force_try
    private static let styleRegexDoubleQuote: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "style\\s*=\\s*\"([^\"]*)\"",
            options: .caseInsensitive
        )
    }()

    // swiftlint:disable:next force_try
    private static let styleRegexSingleQuote: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "style\\s*=\\s*'([^']*)'",
            options: .caseInsensitive
        )
    }()

    // Regex to match <style> tag content (with dotMatchesLineSeparators for multiline)
    // swiftlint:disable:next force_try
    private static let styleTagRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "(<style[^>]*>)(.*?)(</style>)",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }()

    /// Sanitizes both inline style attributes and <style> tag content in HTML
    func sanitizeStyles(_ html: String) -> String {
        var result = html

        // Sanitize <style> tag content first
        result = sanitizeStyleTags(result)

        // Then sanitize inline style attributes
        result = sanitizeInlineStyles(result)

        return result
    }

    /// Sanitizes content inside <style> tags
    func sanitizeStyleTags(_ html: String) -> String {
        var result = html
        let matches = Self.styleTagRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let openTagRange = Range(match.range(at: 1), in: result),
                  let contentRange = Range(match.range(at: 2), in: result),
                  let closeTagRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            let openTag = String(result[openTagRange])
            let cssContent = String(result[contentRange])
            let closeTag = String(result[closeTagRange])

            let sanitizedCSS = sanitizeCSS(cssContent)
            result.replaceSubrange(fullRange, with: "\(openTag)\(sanitizedCSS)\(closeTag)")
        }

        return result
    }

    /// Sanitizes inline style attributes in HTML
    func sanitizeInlineStyles(_ html: String) -> String {
        var result = html

        // Process double-quoted style attributes: style="..."
        let doubleQuoteMatches = Self.styleRegexDoubleQuote.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in doubleQuoteMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let styleContent = String(result[range])
                let sanitizedStyle = sanitizeCSS(styleContent)
                guard let fullRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(fullRange, with: "style=\"\(sanitizedStyle)\"")
            }
        }

        // Process single-quoted style attributes: style='...'
        let singleQuoteMatches = Self.styleRegexSingleQuote.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in singleQuoteMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let styleContent = String(result[range])
                let sanitizedStyle = sanitizeCSS(styleContent)
                guard let fullRange = Range(match.range, in: result) else { continue }
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
