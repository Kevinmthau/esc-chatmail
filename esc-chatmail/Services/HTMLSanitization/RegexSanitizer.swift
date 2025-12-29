import Foundation

/// Utility for applying regex-based sanitization rules to strings
/// Eliminates boilerplate in HTML sanitization methods
struct RegexSanitizer {
    /// Applies a single regex pattern replacement
    static func replace(
        in text: String,
        pattern: String,
        with replacement: String = "",
        options: String.CompareOptions = [.regularExpression, .caseInsensitive]
    ) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: options)
    }

    /// Applies multiple regex pattern replacements in sequence
    static func applyRules(to text: String, rules: [(pattern: String, replacement: String)]) -> String {
        rules.reduce(text) { result, rule in
            replace(in: result, pattern: rule.pattern, with: rule.replacement)
        }
    }

    /// Removes HTML tags (with content) matching any of the given tag names
    static func removeTags(from html: String, tags: [String]) -> String {
        tags.reduce(html) { result, tag in
            let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)>|<\(tag)\\b[^>]*/?>"
            return replace(in: result, pattern: pattern)
        }
    }
}
