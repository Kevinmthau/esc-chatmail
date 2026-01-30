import Foundation

/// Decodes HTML entities to their character equivalents
/// Handles named entities, numeric entities, and zero-width characters
enum HTMLEntityDecoder {

    // MARK: - Entity Lookup Tables

    /// Named HTML entities mapped to their character equivalents
    private static let namedEntities: [String: String] = [
        // Basic entities
        "&nbsp;": " ",
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",

        // Smart quotes and typographic entities
        "&ldquo;": "\"",
        "&rdquo;": "\"",
        "&lsquo;": "'",
        "&rsquo;": "'",

        // Dashes and ellipsis
        "&ndash;": "–",
        "&mdash;": "—",
        "&hellip;": "…",

        // Zero-width characters (strip entirely)
        "&zwnj;": "",
        "&zwj;": "",
    ]

    /// Numeric HTML entities mapped to their character equivalents
    private static let numericEntities: [String: String] = [
        // Quotes
        "&#34;": "\"",
        "&#39;": "'",
        "&#8220;": "\"",
        "&#8221;": "\"",
        "&#8216;": "'",
        "&#8217;": "'",

        // Dashes and ellipsis
        "&#8211;": "–",
        "&#8212;": "—",
        "&#8230;": "…",

        // Zero-width characters
        "&#8204;": "",
        "&#8205;": "",
    ]

    /// Hex entities (case-insensitive matching required)
    private static let hexEntities: [String: String] = [
        "&#x200C;": "",  // Zero-width non-joiner
        "&#x200D;": "",  // Zero-width joiner
    ]

    /// Unicode characters to strip (zero-width formatting)
    private static let zeroWidthCharacters: [Character] = [
        "\u{200B}",  // Zero-width space
        "\u{200C}",  // Zero-width non-joiner
        "\u{200D}",  // Zero-width joiner
    ]

    // MARK: - Public API

    /// Decodes all HTML entities in the given text
    /// - Parameter text: The text containing HTML entities
    /// - Returns: Text with entities decoded to their character equivalents
    static func decode(_ text: String) -> String {
        var result = text

        // Decode named entities
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Decode numeric entities
        for (entity, replacement) in numericEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Decode hex entities (case-insensitive)
        for (entity, replacement) in hexEntities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // Decode any remaining numeric entities not in the hardcoded lists
        result = decodeNumericEntities(result)

        // Strip zero-width Unicode characters
        result = result.filter { !zeroWidthCharacters.contains($0) }

        return result
    }

    // MARK: - Universal Numeric Entity Decoder

    /// Decodes all numeric HTML entities (&#NNN; and &#xNNN;) to their Unicode equivalents
    /// This handles any numeric entity not covered by the hardcoded lookup tables
    private static func decodeNumericEntities(_ text: String) -> String {
        var result = text

        // Decode decimal numeric entities: &#160; &#8217; etc.
        let decimalPattern = "&#(\\d+);"
        if let regex = try? NSRegularExpression(pattern: decimalPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            // Process in reverse to preserve indices
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = Int(result[codeRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }

        // Decode hex numeric entities: &#x00A0; &#xA0; etc.
        let hexPattern = "&#[xX]([0-9a-fA-F]+);"
        if let regex = try? NSRegularExpression(pattern: hexPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = Int(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }

        return result
    }
}
