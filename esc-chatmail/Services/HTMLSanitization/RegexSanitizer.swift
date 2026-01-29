import Foundation

/// Utility for applying regex-based sanitization rules to strings
/// Eliminates boilerplate in HTML sanitization methods
struct RegexSanitizer {
    /// Applies a single regex pattern replacement (compiles regex each call - use for infrequent operations)
    static func replace(
        in text: String,
        pattern: String,
        with replacement: String = "",
        options: String.CompareOptions = [.regularExpression, .caseInsensitive]
    ) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: options)
    }

    /// Applies a pre-compiled regex pattern replacement (more efficient for repeated use)
    static func replace(
        in text: String,
        regex: NSRegularExpression,
        with replacement: String = ""
    ) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    /// Applies multiple regex pattern replacements in sequence
    static func applyRules(to text: String, rules: [(pattern: String, replacement: String)]) -> String {
        rules.reduce(text) { result, rule in
            replace(in: result, pattern: rule.pattern, with: rule.replacement)
        }
    }

    /// Applies multiple pre-compiled regex replacements in sequence (more efficient)
    static func applyRules(to text: String, compiledRules: [(regex: NSRegularExpression, replacement: String)]) -> String {
        compiledRules.reduce(text) { result, rule in
            replace(in: result, regex: rule.regex, with: rule.replacement)
        }
    }

    /// Removes HTML tags (with content) matching any of the given tag names
    /// Uses compiled patterns with dotMatchesLineSeparators to handle multiline content
    static func removeTags(from html: String, tags: [String]) -> String {
        tags.reduce(html) { result, tag in
            if let regex = compileTagPattern(tag) {
                return replace(in: result, regex: regex)
            }
            // Fallback to string-based replacement if regex compilation fails
            let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)>|<\(tag)\\b[^>]*/?>"
            return replace(in: result, pattern: pattern)
        }
    }

    /// Removes HTML tags using pre-compiled regex patterns (more efficient for repeated use)
    static func removeTags(from html: String, compiledPatterns: [NSRegularExpression]) -> String {
        compiledPatterns.reduce(html) { result, regex in
            replace(in: result, regex: regex)
        }
    }

    /// Helper to compile a tag removal pattern
    static func compileTagPattern(_ tag: String) -> NSRegularExpression? {
        let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)>|<\(tag)\\b[^>]*/?>"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }
}
