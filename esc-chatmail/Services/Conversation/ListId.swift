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
    /// Optional human-readable display phrase preceding the bracketed id, quotes stripped.
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

        // Some bulk-mail providers put an internal account token in the phrase
        // position (for example, Mailchimp's "<opaque-token>mc list"). It is
        // metadata, not a title, even though the header is syntactically valid.
        title = sanitizedDisplayTitle(title, listId: id)

        return ParsedListId(id: id, title: title)
    }

    /// Returns a display title only when it is independent human-readable text,
    /// rather than the List-Id itself or an opaque identifier copied from it.
    static func sanitizedDisplayTitle(_ rawTitle: String?, listId: String?) -> String? {
        guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        guard !isIdentifierDerivedDisplayTitle(title, listId: listId) else {
            return nil
        }
        return title
    }

    /// Recognizes both the bare normalized List-Id fallback and provider labels
    /// made from an opaque List-Id component plus a known generic suffix.
    static func isIdentifierDerivedDisplayTitle(_ rawTitle: String?, listId: String?) -> Bool {
        guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              let listId = listId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              !listId.isEmpty else {
            return false
        }

        if title.caseInsensitiveCompare(listId) == .orderedSame {
            return true
        }

        let titleKey = alphanumericKey(title)
        guard !titleKey.isEmpty else { return false }

        return listId.split(separator: ".").contains { label in
            let labelKey = alphanumericKey(String(label))
            guard isOpaqueIdentifierKey(labelKey), titleKey.hasPrefix(labelKey) else {
                return false
            }
            let suffixKey = String(titleKey.dropFirst(labelKey.count))
            return providerGenericTitleSuffixKeys.contains(suffixKey)
        }
    }

    private static func alphanumericKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func isOpaqueIdentifierKey(_ value: String) -> Bool {
        guard value.count >= 20 else { return false }

        if value.allSatisfy({ hexadecimalCharacters.contains($0) }) {
            return true
        }

        var digitCount = 0
        var kindTransitions = 0
        var previousWasNumber: Bool?
        for character in value {
            let isNumber = character.isNumber
            if isNumber {
                digitCount += 1
            }
            if let previousWasNumber, previousWasNumber != isNumber {
                kindTransitions += 1
            }
            previousWasNumber = isNumber
        }

        return digitCount >= 6 && kindTransitions >= 4
    }

    /// Mailchimp emits `<account-token>mc list`. Keep this allowlist narrow so
    /// digit-heavy human titles are not mistaken for provider metadata.
    private static let providerGenericTitleSuffixKeys: Set<String> = ["mclist"]
    private static let hexadecimalCharacters = Set("0123456789abcdef")
}
