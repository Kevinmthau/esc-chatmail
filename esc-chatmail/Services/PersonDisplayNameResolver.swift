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

    static func fallbackConversationName(participantCount: Int) -> String {
        participantCount > 1 ? "\(participantCount) Unknown Contacts" : unknownContactName
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
                ?? fallbackConversationName(participantCount: totalParticipantCount)
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
                ?? fallbackConversationName(participantCount: totalParticipantCount)
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
              !placeholderDisplayNames.contains(normalized.lowercased()),
              !EmailNormalizer.isHideMyEmailDisplayName(normalized),
              !looksLikeEmailAddress(normalized) else {
            return nil
        }

        return normalized
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
        guard let organizationLabel = domainLabels.dropLast().last else { return false }
        return organizationLabel == localPartKey
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
}
