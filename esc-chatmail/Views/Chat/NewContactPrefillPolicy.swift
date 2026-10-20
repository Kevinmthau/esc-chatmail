import Foundation

/// What the Contacts "new contact" screen starts with when the user taps Create New
/// Contact on a Participants-sheet row.
///
/// The prefilled name is the row's own resolved name (`ParticipantLoader.ResolvedParticipant`),
/// so the sheet and the add screen never disagree, and only when the resolver accepted it as a
/// real name: a row reading "Unknown Contact" prefills the email alone. The choice among name
/// sources (Contacts, then the newest explicit From header name, then the stored Person name)
/// stays in `PersonDisplayNameResolver.participantDisplayName`; this policy never re-ranks them.
///
/// This used to read `Person.displayName` directly. That is not the name the chat header shows:
/// the header shows the newest From header name, while the Person row holds the name merged
/// across every header that ever named the address, and `EmailNormalizer.isBetterDisplayName`
/// can let an email-address-shaped name ("jacob.laycock@studs.com") replace an address-derived
/// one ("Jacob Laycock"). The add screen then came up without the name the header showed.
enum NewContactPrefillPolicy {
    /// The `CNMutableContact` name fields to prefill. Empty strings leave a field blank.
    struct NameComponents: Equatable {
        var namePrefix = ""
        var givenName = ""
        var middleName = ""
        var familyName = ""
        var nameSuffix = ""
    }

    struct Prefill: Equatable {
        let email: String
        /// nil prefills the email alone.
        let name: NameComponents?
    }

    static func prefill(for participant: ParticipantLoader.ResolvedParticipant) -> Prefill {
        let name = participant.isRealDisplayName
            ? nameComponents(forDisplayName: participant.displayName, email: participant.email)
            : nil
        return Prefill(email: participant.email, name: name)
    }

    /// Splits a display name into Contacts name fields, or returns nil when the name is not a
    /// person's name to prefill: empty, a placeholder ("Unknown Contact"), an email address used
    /// as a display name, or the address's raw local part.
    ///
    /// Deterministic rules rather than `PersonNameComponentsFormatter`, whose parse depends on
    /// the device locale and OS version:
    /// - wrapping quotes ("…", '…', “…”, ‘…’) and a trailing "(…)" / "[…]" qualifier are dropped;
    /// - "Last, First [Middle]" swaps into given and family name;
    /// - one token is a given name, except after an honorific ("Dr. Smith"), where it is the
    ///   family name;
    /// - a leading honorific and trailing generational or degree suffixes go to their own fields;
    /// - otherwise the first token is the given name, the last token (with any lowercase
    ///   particles before it, "van", "de la") the family name, and the rest the middle name;
    /// - a two-token CJK name ("山田 太郎") is family name first.
    static func nameComponents(forDisplayName displayName: String?, email: String) -> NameComponents? {
        guard let cleaned = cleanedDisplayName(displayName, email: email) else { return nil }

        var segments = cleaned
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        var commaSuffix = ""
        if segments.count > 1, let last = segments.last, isSuffixPhrase(last) {
            commaSuffix = last
            segments.removeLast()
        }

        var components: NameComponents
        switch segments.count {
        case 1:
            components = forwardComponents(tokens(in: segments[0]))
        case 2:
            // "Last, First [Middle]": the right side carries the given and middle names (and any
            // honorific or suffix), the left side the family name.
            let rightSide = forwardComponents(tokens(in: segments[1]), familyNameKnown: true)
            components = rightSide
            components.familyName = segments[0]
        default:
            // Three or more comma segments is not a recognizable person-name shape; keep the
            // whole name rather than guess at an order.
            components = NameComponents(givenName: cleaned)
        }

        if !commaSuffix.isEmpty {
            components.nameSuffix = [components.nameSuffix, commaSuffix]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        guard !(components.givenName.isEmpty && components.familyName.isEmpty) else {
            return NameComponents(givenName: cleaned)
        }
        return components
    }

    // MARK: - Cleaning

    private static let wrappingQuotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""),
        ("'", "'"),
        ("\u{201C}", "\u{201D}"),
        ("\u{2018}", "\u{2019}"),
        ("\u{00AB}", "\u{00BB}")
    ]

    private static let trailingQualifierRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s*(\([^()]*\)|\[[^\[\]]*\])\s*$"#)
    }()

    private static func cleanedDisplayName(_ displayName: String?, email: String) -> String? {
        guard var candidate = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return nil
        }

        candidate = strippingWrappingQuotes(candidate)

        // "Jacob Laycock (Studs)" / "Jacob Laycock (via Google Docs)": the qualifier is not part
        // of the name. Stripped before the sanitizer so an address inside it does not disqualify
        // the name in front of it.
        let withoutQualifier = RegexSanitizer.replace(in: candidate, regex: trailingQualifierRegex, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !withoutQualifier.isEmpty {
            candidate = strippingWrappingQuotes(withoutQualifier)
        }

        return PersonDisplayNameResolver.sanitizedExplicitDisplayName(candidate, forEmail: email)
    }

    private static func strippingWrappingQuotes(_ value: String) -> String {
        var result = value
        var didStrip = true
        while didStrip, result.count >= 2 {
            didStrip = false
            for pair in wrappingQuotePairs where result.first == pair.open && result.last == pair.close {
                result = String(result.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
                break
            }
        }
        return result
    }

    // MARK: - Splitting

    private static let honorificPrefixes: Set<String> = [
        "dr", "mr", "mrs", "ms", "mx", "miss", "prof", "rev", "sir", "dame"
    ]

    /// Generational and degree suffixes. A lone "V" is left out: it is far more often an initial.
    private static let nameSuffixes: Set<String> = [
        "jr", "sr", "ii", "iii", "iv", "phd", "md", "dds", "esq"
    ]

    /// Family-name particles, matched only when written in lowercase ("Ludwig van Beethoven"):
    /// a capitalized "Van" or "Le" is as likely a middle or given name.
    private static let familyNameParticles: Set<String> = [
        "al", "bin", "da", "das", "de", "del", "della", "den", "der", "di", "do", "dos", "du",
        "el", "la", "le", "st.", "ten", "ter", "van", "von"
    ]

    private static func tokens(in value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func comparisonKey(_ token: String) -> String {
        token.lowercased().filter { $0 != "." && $0 != "," }
    }

    private static func isSuffixPhrase(_ value: String) -> Bool {
        let parts = tokens(in: value)
        return !parts.isEmpty && parts.allSatisfy { nameSuffixes.contains(comparisonKey($0)) }
    }

    /// Parses a name written given-name first. With `familyNameKnown` (the right side of
    /// "Last, First"), every remaining token is a given or middle name.
    private static func forwardComponents(_ allTokens: [String], familyNameKnown: Bool = false) -> NameComponents {
        var tokens = allTokens
        var components = NameComponents()

        if tokens.count > 1, honorificPrefixes.contains(comparisonKey(tokens[0])) {
            components.namePrefix = tokens.removeFirst()
        }

        var suffixes: [String] = []
        while tokens.count > 1, let last = tokens.last, nameSuffixes.contains(comparisonKey(last)) {
            suffixes.insert(tokens.removeLast(), at: 0)
        }
        components.nameSuffix = suffixes.joined(separator: " ")

        guard !tokens.isEmpty else { return components }

        if familyNameKnown {
            components.givenName = tokens[0]
            components.middleName = tokens.dropFirst().joined(separator: " ")
            return components
        }

        if tokens.count == 1 {
            if components.namePrefix.isEmpty {
                components.givenName = tokens[0]
            } else {
                components.familyName = tokens[0]
            }
            return components
        }

        if tokens.count == 2, tokens.allSatisfy(isCJKToken) {
            components.familyName = tokens[0]
            components.givenName = tokens[1]
            return components
        }

        var familyStart = tokens.count - 1
        while familyStart > 1, isLowercaseParticle(tokens[familyStart - 1]) {
            familyStart -= 1
        }

        components.givenName = tokens[0]
        components.middleName = tokens[1..<familyStart].joined(separator: " ")
        components.familyName = tokens[familyStart...].joined(separator: " ")
        return components
    }

    private static func isLowercaseParticle(_ token: String) -> Bool {
        token == token.lowercased() && familyNameParticles.contains(token)
    }

    private static func isCJKToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x1100...0x11FF,   // Hangul Jamo
                 0x3005,            // Ideographic iteration mark
                 0x3040...0x30FF,   // Hiragana, Katakana
                 0x3130...0x318F,   // Hangul Compatibility Jamo
                 0x31F0...0x31FF,   // Katakana Phonetic Extensions
                 0x3400...0x4DBF,   // CJK Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xAC00...0xD7AF,   // Hangul Syllables
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x20000...0x2FA1F: // CJK Extensions B+ and Compatibility Supplement
                return true
            default:
                return false
            }
        }
    }
}
