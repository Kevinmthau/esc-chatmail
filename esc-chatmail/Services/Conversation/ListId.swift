import Foundation

/// Parsed RFC 2919 List-Id header value.
///
/// A List-Id looks like `Friends of Bob <friends-of-bob.example.com>` or just
/// `<friends-of-bob.example.com>`. The bracketed identifier is the stable
/// grouping key for list conversations; the optional leading phrase is a
/// human-readable title consumed once at conversation creation.
struct ParsedListId: Equatable, Sendable {
    /// Normalized list identifier: bracket content, trimmed and lowercased.
    let id: String
    /// Optional display phrase preceding the bracketed id, quotes stripped.
    let title: String?

    /// Parses a raw List-Id header value. Returns nil for values that yield no
    /// usable identifier — callers fall back to participant-set grouping, so
    /// rejecting a malformed value is the safe path, not an error.
    static func parse(_ rawHeaderValue: String?) -> ParsedListId? {
        guard let raw = rawHeaderValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let id: String
        var title: String?
        if let openBracket = raw.lastIndex(of: "<") {
            // An opened bracket must be terminated; a dangling `<` is malformed.
            guard let closeBracket = raw[openBracket...].firstIndex(of: ">") else { return nil }
            id = String(raw[raw.index(after: openBracket)..<closeBracket])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            var phrase = String(raw[..<openBracket]).trimmingCharacters(in: .whitespaces)
            if phrase.hasPrefix("\""), phrase.hasSuffix("\""), phrase.count >= 2 {
                phrase = String(phrase.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            title = phrase.isEmpty ? nil : phrase
        } else {
            // Bracket-less values are technically malformed but seen in the
            // wild; the whole value serves as the identifier.
            id = raw.lowercased()
        }

        // RFC 2919 list-ids are dot-atom-text: whitespace inside the
        // identifier means garbage that would make a poor grouping key.
        guard !id.isEmpty, id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }

        return ParsedListId(id: id, title: title)
    }
}
