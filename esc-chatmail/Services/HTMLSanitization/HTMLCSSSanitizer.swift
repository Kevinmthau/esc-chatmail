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

    /// `cssSanitizationRules` compiled once. The string-pattern
    /// `RegexSanitizer.applyRules(to:rules:)` recompiled all ten per call, and
    /// `sanitizeCSS` runs once per `style` attribute and `<style>` block.
    /// `.caseInsensitive` on every rule is load-bearing: it is what the
    /// per-call path's default options supplied, and without it `JAVASCRIPT:`
    /// would pass. `sanitizeCSS` falls back to the per-call path if any rule
    /// failed to compile, so a compile failure cannot drop a rule.
    private static let compiledCSSSanitizationRules: [(regex: NSRegularExpression, replacement: String)] = {
        cssSanitizationRules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]))
                .map { (regex: $0, replacement: rule.replacement) }
        }
    }()

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
            // The open and close tags are re-inserted verbatim, so when the CSS
            // did not change the replacement equals the existing text; skip the
            // O(n) tail move (and the String's UTF-16 breadcrumb reset) then.
            guard !sanitizedCSS.utf8.elementsEqual(cssContent.utf8) else { continue }
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
                // Compare the whole replacement, not just the CSS: the rewrite
                // also normalizes `STYLE=` / `style = "` to `style="`, which
                // must still happen when the CSS itself is clean.
                let replacement = "style=\"\(sanitizedStyle)\""
                guard !result[fullRange].utf8.elementsEqual(replacement.utf8) else { continue }
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        // Process single-quoted style attributes: style='...'
        let singleQuoteMatches = Self.styleRegexSingleQuote.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in singleQuoteMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let styleContent = String(result[range])
                let sanitizedStyle = sanitizeCSS(styleContent)
                guard let fullRange = Range(match.range, in: result) else { continue }
                // A single-quoted attribute always rewrites to double quotes, so
                // this guard only ever skips when the text already matched.
                let replacement = "style=\"\(sanitizedStyle)\""
                guard !result[fullRange].utf8.elementsEqual(replacement.utf8) else { continue }
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        return result
    }

    /// Sanitizes CSS content
    func sanitizeCSS(_ css: String) -> String {
        guard Self.compiledCSSSanitizationRules.count == Self.cssSanitizationRules.count else {
            return RegexSanitizer.applyRules(to: css, rules: Self.cssSanitizationRules)
        }
        return RegexSanitizer.applyRules(to: css, compiledRules: Self.compiledCSSSanitizationRules)
    }
}
