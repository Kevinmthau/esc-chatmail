import Foundation

enum PersonDisplayNameResolver {
    private static let unknownSenderName = "Unknown Sender"
    private static let unknownContactName = "Unknown Contact"

    static func isRealDisplayName(_ displayName: String?, forEmail email: String) -> Bool {
        sanitizedRealDisplayName(displayName, forEmail: email) != nil
    }

    static func sanitizedRealDisplayName(_ displayName: String?, forEmail email: String) -> String? {
        guard let candidate = normalizedCandidate(displayName) else { return nil }
        guard !EmailNormalizer.isAddressDerivedDisplayName(candidate, forEmail: email) else {
            return nil
        }
        return candidate
    }

    static func sanitizedExplicitDisplayName(_ displayName: String?, forEmail email: String) -> String? {
        guard let candidate = normalizedCandidate(displayName) else { return nil }
        guard !isRawEmailLocalPart(candidate, forEmail: email) else { return nil }
        return candidate
    }

    static func fallbackSenderName() -> String {
        unknownSenderName
    }

    static func fallbackConversationName() -> String {
        unknownContactName
    }

    static func fallbackConversationName(participantEmails: [String]) -> String {
        var seenKeys = Set<String>()
        var unique: [String] = []
        for email in participantEmails {
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = EmailNormalizer.normalize(trimmed)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            unique.append(trimmed)
        }
        guard !unique.isEmpty else { return unknownContactName }
        unique.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let maxVisible = 3
        guard unique.count > maxVisible else {
            return unique.joined(separator: ", ")
        }
        let visible = unique.prefix(maxVisible).joined(separator: ", ")
        return "\(visible) +\(unique.count - maxVisible)"
    }

    static func senderDisplayName(
        email: String,
        contactDisplayName: String?,
        headerDisplayName: String?,
        storedDisplayName: String?
    ) -> String {
        if let contactDisplayName = sanitizedExplicitDisplayName(contactDisplayName, forEmail: email) {
            return contactDisplayName
        }
        if let headerDisplayName = sanitizedExplicitDisplayName(headerDisplayName, forEmail: email) {
            return headerDisplayName
        }
        if let storedDisplayName = sanitizedRealDisplayName(storedDisplayName, forEmail: email) {
            return storedDisplayName
        }
        return fallbackSenderName()
    }

    static func participantDisplayName(
        email: String,
        contactDisplayName: String?,
        headerDisplayName: String?,
        storedDisplayName: String?
    ) -> (name: String, isReal: Bool) {
        if let contactDisplayName = sanitizedExplicitDisplayName(contactDisplayName, forEmail: email) {
            return (contactDisplayName, true)
        }
        if let headerDisplayName = sanitizedExplicitDisplayName(headerDisplayName, forEmail: email) {
            return (headerDisplayName, true)
        }
        if let storedDisplayName = sanitizedRealDisplayName(storedDisplayName, forEmail: email) {
            return (storedDisplayName, true)
        }
        return (fallbackConversationName(), false)
    }

    static func conversationDisplayName(
        realNames: [String],
        totalParticipantCount: Int,
        fallback: String?,
        participantEmails: [String]
    ) -> String {
        let names = uniqueNames(realNames)
        if names.isEmpty {
            return sanitizedConversationDisplayNameHint(fallback, participantEmails: participantEmails)
                ?? fallbackConversationName(participantEmails: participantEmails)
        }

        let baseName = DisplayNameFormatter.formatGroupNames(names)
        let unresolvedCount = max(totalParticipantCount - names.count, 0)
        guard unresolvedCount > 0 else { return baseName }
        return "\(baseName) +\(unresolvedCount)"
    }

    static func rowDisplayName(
        realNames: [String],
        totalParticipantCount: Int,
        fallback: String?,
        participantEmails: [String]
    ) -> String {
        let names = uniqueNames(realNames)
        if names.isEmpty {
            return sanitizedConversationDisplayNameHint(fallback, participantEmails: participantEmails)
                ?? fallbackConversationName(participantEmails: participantEmails)
        }

        return DisplayNameFormatter.formatForRow(
            names: names,
            totalCount: totalParticipantCount,
            fallback: nil
        )
    }

    static func sanitizedConversationDisplayNameHint(
        _ displayName: String?,
        participantEmails: [String]
    ) -> String? {
        guard let candidate = normalizedCandidate(displayName) else { return nil }
        guard !participantEmails.contains(where: { email in
            EmailNormalizer.isAddressDerivedDisplayName(candidate, forEmail: email)
        }) else {
            return nil
        }
        guard !isLikelyAddressDerivedGroupName(candidate, participantEmails: participantEmails) else {
            return nil
        }
        return candidate
    }

    private static func normalizedCandidate(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !normalized.isEmpty,
              !isPlaceholderDisplayName(normalized),
              !EmailNormalizer.isHideMyEmailDisplayName(normalized),
              !looksLikeEmailAddress(normalized) else {
            return nil
        }

        return normalized
    }

    private static func isPlaceholderDisplayName(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return placeholderDisplayNames.contains(lowercased)
            || lowercased.range(
                of: #"^\d+\s+unknown contacts?$"#,
                options: .regularExpression
            ) != nil
    }

    private static func looksLikeEmailAddress(_ value: String) -> Bool {
        value.contains("@") && EmailNormalizer.extractEmail(from: value) != nil
    }

    private static func isRawEmailLocalPart(_ displayName: String, forEmail email: String) -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPart: String
        if let atIndex = trimmedEmail.firstIndex(of: "@") {
            localPart = String(trimmedEmail[..<atIndex])
        } else {
            localPart = trimmedEmail
        }

        let separatorCharacters = CharacterSet(charactersIn: "._-+")
        let localPartUsesAddressSeparators = localPart.rangeOfCharacter(from: separatorCharacters) != nil
        if displayName == localPart {
            return !isLikelyBrandLocalPart(localPart, forEmail: trimmedEmail)
        }
        return localPartUsesAddressSeparators && displayName.caseInsensitiveCompare(localPart) == .orderedSame
    }

    private static func isLikelyBrandLocalPart(_ localPart: String, forEmail email: String) -> Bool {
        let scalars = Array(localPart.unicodeScalars)
        guard !scalars.isEmpty,
              scalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return false
        }

        var sawLetter = false
        var sawDigitAfterLetter = false
        for scalar in scalars {
            if CharacterSet.letters.contains(scalar) {
                if sawDigitAfterLetter {
                    return true
                }
                sawLetter = true
            } else if CharacterSet.decimalDigits.contains(scalar), sawLetter {
                sawDigitAfterLetter = true
            }
        }

        if localPartMatchesDomainBrand(localPart, forEmail: email) {
            return true
        }

        return false
    }

    private static func localPartMatchesDomainBrand(_ localPart: String, forEmail email: String) -> Bool {
        guard let atIndex = email.firstIndex(of: "@") else { return false }
        let domain = email[email.index(after: atIndex)...].lowercased()
        let domainLabels = domain.split(separator: ".")
        guard domainLabels.count > 1 else { return false }

        let localPartKey = localPart.lowercased()
        guard let organizationLabel = organizationLabel(in: domainLabels) else { return false }
        return organizationLabel == localPartKey
    }

    private static func organizationLabel(in domainLabels: [Substring]) -> Substring? {
        let suffixLabelCount = publicSuffixLabelCount(for: domainLabels)
        let organizationLabelIndex = domainLabels.count - suffixLabelCount - 1
        guard organizationLabelIndex >= 0 else { return nil }
        return domainLabels[organizationLabelIndex]
    }

    private static func publicSuffixLabelCount(for domainLabels: [Substring]) -> Int {
        guard let topLevelLabel = domainLabels.last,
              topLevelLabel.count == 2,
              let secondLevelLabel = domainLabels.dropLast().last,
              let publicSuffixTLDs = knownCountryCodeSecondLevelPublicSuffixTLDs[String(secondLevelLabel)],
              publicSuffixTLDs.contains(String(topLevelLabel)) else {
            return 1
        }

        return 2
    }

    private static func isLikelyAddressDerivedGroupName(
        _ displayName: String,
        participantEmails: [String]
    ) -> Bool {
        let derivedFirstNames = Set(participantEmails.compactMap { email -> String? in
            let derivedName = EmailNormalizer.formatAsDisplayName(email: email)
            return firstNameKey(derivedName)
        })
        guard !derivedFirstNames.isEmpty else { return false }

        let displayFirstNames = displayName
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .components(separatedBy: ",")
            .compactMap { segment -> String? in
                let nameSegment = segment
                    .replacingOccurrences(of: #"\+\d+$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return firstNameKey(nameSegment)
            }

        return !displayFirstNames.isEmpty && displayFirstNames.allSatisfy(derivedFirstNames.contains)
    }

    private static func firstNameKey(_ value: String) -> String? {
        let firstName = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first?
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()

        guard let firstName, !firstName.isEmpty else { return nil }
        return firstName
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for name in names {
            guard let normalized = normalizedCandidate(name) else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
        }

        return result
    }

    private static let placeholderDisplayNames: Set<String> = [
        "no participants",
        "unknown",
        "unknown contact",
        "unknown contacts",
        "unknown sender"
    ]

    // Exact ICANN public suffix pairs for the generic ccTLD labels this resolver recognizes.
    // Broad label-only matching misclassifies registrable pairs like com.ch and com.se.
    private static let knownCountryCodeSecondLevelPublicSuffixTLDs: [String: Set<String>] = [
        "ac": [
            "ae", "at", "bd", "be", "bw", "ci", "cn", "cr", "cy", "eg", "fj", "gn", "id", "il",
            "im", "in", "ir", "jp", "ke", "kr", "lk", "ls", "ma", "me", "ml", "mu", "mw", "mz",
            "ni", "nz", "pa", "pk", "pr", "rs", "rw", "se", "sz", "th", "tj", "tz", "ug", "uk",
            "vn", "za", "zm", "zw"
        ],
        "asn": [
            "au", "lv"
        ],
        "co": [
            "ae", "ag", "am", "ao", "at", "az", "bb", "bd", "bi", "bj", "bw", "bz", "ci", "cl",
            "cm", "cr", "dm", "gg", "gl", "gy", "hu", "id", "il", "im", "in", "io", "ir", "it",
            "je", "jp", "ke", "kr", "lc", "ls", "ma", "me", "mg", "mu", "mw", "mz", "na", "ni",
            "nz", "om", "pn", "rs", "rw", "ss", "st", "sz", "th", "tj", "tm", "tt", "tz", "ug",
            "uk", "us", "uz", "ve", "vi", "za", "zm", "zw"
        ],
        "com": [
            "ac", "af", "ag", "ai", "al", "am", "ar", "au", "aw", "az", "ba", "bb", "bd", "bh",
            "bi", "bj", "bm", "bn", "bo", "br", "bs", "bt", "by", "bz", "ci", "cm", "cn", "co",
            "cu", "cv", "cw", "cy", "dm", "do", "dz", "ec", "ee", "eg", "es", "et", "fj", "fm",
            "fr", "ge", "gh", "gi", "gl", "gn", "gp", "gr", "gt", "gu", "gy", "hk", "hn", "hr",
            "ht", "im", "in", "io", "iq", "jo", "kg", "kh", "ki", "km", "kp", "kw", "ky", "kz",
            "la", "lb", "lc", "lk", "lr", "lv", "ly", "mg", "mk", "ml", "mo", "ms", "mt", "mu",
            "mv", "mw", "mx", "my", "na", "nf", "ng", "ni", "nr", "om", "pa", "pe", "pf", "ph",
            "pk", "pl", "pr", "ps", "pt", "py", "qa", "re", "ro", "sa", "sb", "sc", "sd", "sg",
            "sh", "sl", "sn", "so", "ss", "st", "sv", "sy", "tj", "tm", "tn", "to", "tr", "tt",
            "tw", "ua", "ug", "uy", "uz", "vc", "ve", "vi", "vn", "vu", "ws", "ye", "zm"
        ],
        "ed": [
            "ao", "ci", "cr", "jp"
        ],
        "edu": [
            "ac", "af", "al", "ao", "ar", "au", "az", "ba", "bb", "bd", "bh", "bi", "bj", "bm",
            "bn", "bo", "br", "bs", "bt", "bz", "ci", "cn", "co", "cu", "cv", "cw", "dm", "do",
            "dz", "ec", "ee", "eg", "es", "et", "fj", "fm", "gd", "ge", "gh", "gi", "gl", "gn",
            "gp", "gr", "gt", "gu", "gy", "hk", "hn", "ht", "in", "io", "iq", "it", "jo", "kg",
            "kh", "ki", "km", "kn", "kp", "kw", "ky", "kz", "la", "lb", "lc", "lk", "lr", "ls",
            "lv", "ly", "me", "mg", "mk", "ml", "mn", "mo", "ms", "mt", "mv", "mw", "mx", "my",
            "mz", "ng", "ni", "nr", "om", "pa", "pe", "pf", "ph", "pk", "pl", "pn", "pr", "ps",
            "pt", "py", "qa", "rs", "sa", "sb", "sc", "sd", "sg", "sl", "sn", "so", "ss", "st",
            "sv", "sy", "tj", "tm", "to", "tr", "tt", "tw", "ua", "ug", "uy", "vc", "ve", "vg",
            "vn", "vu", "ws", "ye", "za", "zm"
        ],
        "firm": [
            "ht", "in", "nf", "ro", "ve"
        ],
        "gen": [
            "in", "nz", "tr"
        ],
        "go": [
            "ci", "cr", "id", "it", "jp", "ke", "kr", "th", "tj", "tz", "ug"
        ],
        "gob": [
            "ar", "bo", "cl", "cu", "do", "ec", "es", "gt", "hn", "mx", "ni", "pa", "pe", "pk",
            "sv", "ve"
        ],
        "gov": [
            "ac", "ae", "af", "al", "ao", "ar", "as", "au", "az", "ba", "bb", "bd", "bf", "bh",
            "bm", "bn", "br", "bs", "bt", "bw", "by", "bz", "cd", "cl", "cm", "cn", "co", "cx",
            "cy", "cz", "dm", "do", "dz", "ec", "ee", "eg", "et", "fj", "gd", "ge", "gh", "gi",
            "gn", "gr", "gu", "gy", "hk", "ie", "il", "in", "io", "iq", "ir", "it", "jo", "kg",
            "kh", "ki", "km", "kn", "kp", "kw", "kz", "la", "lb", "lc", "lk", "lr", "ls", "lt",
            "lv", "ly", "ma", "me", "mg", "mk", "ml", "mn", "mo", "mr", "ms", "mu", "mv", "mw",
            "my", "mz", "na", "ng", "nr", "om", "ph", "pk", "pl", "pn", "pr", "ps", "pt", "pw",
            "py", "qa", "rs", "rw", "sa", "sb", "sc", "sd", "sg", "sh", "sl", "so", "ss", "sx",
            "sy", "tj", "tl", "tm", "tn", "to", "tr", "tt", "tw", "ua", "ug", "uk", "vc", "ve",
            "vn", "ws", "ye", "za", "zm", "zw"
        ],
        "govt": [
            "nz"
        ],
        "id": [
            "au", "bd", "cv", "fj", "ir", "lv", "ly", "us", "vn"
        ],
        "ind": [
            "br", "gt", "in", "kw", "tn"
        ],
        "ltd": [
            "cy", "gi", "lk", "uk"
        ],
        "me": [
            "eg", "in", "it", "ke", "kr", "so", "ss", "tz", "uk", "us"
        ],
        "ne": [
            "jp", "ke", "kr", "tz", "ug", "us"
        ],
        "net": [
            "ac", "ae", "af", "ag", "ai", "al", "am", "ar", "au", "az", "ba", "bb", "bd", "bh",
            "bj", "bm", "bn", "bo", "br", "bs", "bt", "bw", "bz", "ci", "cm", "cn", "co", "cu",
            "cv", "cw", "cy", "dm", "do", "dz", "ec", "eg", "et", "fj", "fm", "ge", "gg", "gh",
            "gl", "gn", "gp", "gr", "gt", "gu", "gy", "hk", "hn", "ht", "id", "il", "im", "in",
            "io", "iq", "ir", "je", "jo", "kg", "kh", "ki", "kn", "kw", "ky", "kz", "la", "lb",
            "lc", "lk", "lr", "ls", "lv", "ly", "ma", "me", "mk", "ml", "mo", "ms", "mt", "mu",
            "mv", "mw", "mx", "my", "mz", "na", "nf", "ng", "ni", "nr", "nz", "om", "pa", "pe",
            "ph", "pk", "pl", "pn", "pr", "ps", "pt", "py", "qa", "rw", "sa", "sb", "sc", "sd",
            "sg", "sh", "sl", "so", "ss", "st", "sy", "th", "tj", "tm", "tn", "to", "tr", "tt",
            "tw", "ua", "uk", "uy", "uz", "vc", "ve", "vi", "vn", "vu", "ws", "ye", "za", "zm"
        ],
        "or": [
            "at", "bi", "ci", "cr", "id", "it", "jp", "ke", "kr", "mu", "th", "tz", "ug", "us"
        ],
        "org": [
            "ac", "ae", "af", "ag", "ai", "al", "am", "ao", "ar", "au", "az", "ba", "bb", "bd",
            "bh", "bi", "bj", "bm", "bn", "bo", "br", "bs", "bt", "bw", "bz", "ci", "cn", "co",
            "cu", "cv", "cw", "cy", "dm", "do", "dz", "ec", "ee", "eg", "es", "et", "fj", "fm",
            "ge", "gg", "gh", "gi", "gl", "gn", "gp", "gr", "gt", "gu", "gy", "hk", "hn", "ht",
            "hu", "il", "im", "in", "io", "iq", "ir", "je", "jo", "kg", "kh", "ki", "km", "kn",
            "kp", "kw", "ky", "kz", "la", "lb", "lc", "lk", "lr", "ls", "lv", "ly", "ma", "me",
            "mg", "mk", "ml", "mn", "mo", "ms", "mt", "mu", "mv", "mw", "mx", "my", "mz", "na",
            "ng", "ni", "nr", "nz", "om", "pa", "pe", "pf", "ph", "pk", "pl", "pn", "pr", "ps",
            "pt", "py", "qa", "ro", "rs", "rw", "sa", "sb", "sc", "sd", "se", "sg", "sh", "sk",
            "sl", "sn", "so", "ss", "st", "sv", "sy", "sz", "tj", "tm", "tn", "to", "tr", "tt",
            "tw", "ua", "ug", "uk", "uy", "uz", "vc", "ve", "vi", "vn", "vu", "ws", "ye", "za",
            "zm", "zw"
        ],
        "plc": [
            "ly", "uk"
        ],
        "sch": [
            "ae", "bd", "id", "ir", "jo", "lk", "ly", "ng", "qa", "sa", "ss", "zm"
        ],
        "school": [
            "ge", "nz", "za"
        ]
    ]
}
