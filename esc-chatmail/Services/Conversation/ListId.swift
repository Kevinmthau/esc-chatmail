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
        // position (Mailchimp's "<opaque-token>mc list", Brevo's bare
        // "<opaque-token>"). It is metadata, not a title, even though the
        // header is syntactically valid.
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

    /// Recognizes the bare normalized List-Id fallback, provider labels made
    /// from an opaque List-Id component plus a known generic suffix
    /// (Mailchimp's "<token>mc list"), and a bare token that restates an
    /// identifier label on its own (Brevo emits
    /// "ODI2OTI3Ny04MTYyNi0z <ODI2OTI3Ny04MTYyNi0z.list-id.mailin.fr>", and
    /// on custom sending domains "MTAyMjYwMTUtMjM1ODc3LTA=
    /// <MTAyMjYwMTUtMjM1ODc3LTA=.list-id.email-newsletters.timeout.com>").
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

        // A phrase with internal whitespace is human wording even when it
        // compresses to the same alphanumeric key as an identifier label
        // ("Formula 1 2024 Round 12 Highlights" vs
        // "formula1-2024-round12-highlights"); only an unbroken token can be
        // the identifier itself restated in the phrase position.
        let titleIsBareToken = title.rangeOfCharacter(from: .whitespacesAndNewlines) == nil

        let labels = listId.split(separator: ".")
        return labels.indices.contains { index in
            let labelKey = alphanumericKey(String(labels[index]))
            guard !labelKey.isEmpty, titleKey.hasPrefix(labelKey) else {
                return false
            }
            let labelIsOpaqueIdentifier = isOpaqueIdentifierKey(labelKey)
            let suffixKey = String(titleKey.dropFirst(labelKey.count))
            if suffixKey.isEmpty {
                // Token shape is the general signal. The provider-specific
                // fallback applies only to Brevo's verified bare-token form,
                // so an unrelated `list-id` label cannot turn an ordinary
                // one-word title into metadata.
                let labelMatchesKnownProvider = isKnownProviderIdentifierLabel(
                    at: index,
                    in: labels
                )
                return titleIsBareToken
                    && (labelIsOpaqueIdentifier
                        || labelMatchesKnownProvider
                        || isBase64EncodedNumericIdentifier(title))
            }
            return labelIsOpaqueIdentifier
                && providerGenericTitleSuffixKeys.contains(suffixKey)
        }
    }

    private static func isKnownProviderIdentifierLabel(
        at index: Int,
        in labels: [Substring]
    ) -> Bool {
        guard index == labels.startIndex else { return false }
        let suffix = labels.dropFirst(index + 1)
            .map { $0.lowercased() }
            .joined(separator: ".")
        return providerIdentifierSuffixes.contains(suffix)
    }

    private static func alphanumericKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Recognizes a token that is standard base64 for a numeric machine
    /// identifier. Brevo restates its list token in the phrase position on
    /// custom sending domains too ("MTAyMjYwMTUtMjM1ODc3LTA=" is base64 of
    /// "10226015-235877-0"), where no provider suffix can vouch for it and
    /// the encoded form can carry too few literal digits for the opaqueness
    /// profiles — base64 of ASCII digits yields mostly letters at most
    /// alignments. Decoding sidesteps that alignment lottery: the decoded
    /// bytes must read as digits broken only by separator punctuation, a
    /// shape no human brand word decodes to.
    private static func isBase64EncodedNumericIdentifier(_ token: String) -> Bool {
        guard token.count >= 8 else { return false }
        var padded = token
        let remainder = token.count % 4
        if remainder != 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: padded), decoded.count >= 8 else {
            return false
        }

        var digitCount = 0
        for byte in decoded {
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                digitCount += 1
            } else if !base64NumericIdentifierSeparatorBytes.contains(byte) {
                return false
            }
        }
        return digitCount >= 6
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

        // Two machine-token profiles: digit-heavy account identifiers, and
        // base64 of numeric ids (Brevo's "8269277-81626-3" encodes to
        // "ODI2OTI3Ny04MTYyNi0z"), where literal digits are sparse but keep
        // interleaving with letters far more often than words do.
        return (digitCount >= 6 && kindTransitions >= 4)
            || (digitCount >= 4 && kindTransitions >= 6)
    }

    /// Mailchimp emits `<account-token>mc list`. Keep this allowlist narrow so
    /// digit-heavy human titles are not mistaken for provider metadata.
    private static let providerGenericTitleSuffixKeys: Set<String> = ["mclist"]
    /// Brevo restates its account token before this exact List-Id suffix.
    private static let providerIdentifierSuffixes: Set<String> = ["list-id.mailin.fr"]
    /// Separator bytes tolerated between the digit runs of a decoded numeric
    /// identifier (Brevo joins its id components with "-").
    private static let base64NumericIdentifierSeparatorBytes = Set("-_.".utf8)
    private static let hexadecimalCharacters = Set("0123456789abcdef")
}
