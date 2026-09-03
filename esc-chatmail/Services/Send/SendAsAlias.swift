import Foundation
import CoreData

struct SendAsAlias: Codable, Equatable, Sendable {
    let emailAddress: String
    let displayName: String?
    let isDefault: Bool
    let isPrimary: Bool
    let verificationStatus: String?

    init(
        emailAddress: String,
        displayName: String? = nil,
        isDefault: Bool = false,
        isPrimary: Bool = false,
        verificationStatus: String? = nil
    ) {
        self.emailAddress = Self.normalizedAddress(emailAddress)
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.isDefault = isDefault
        self.isPrimary = isPrimary
        self.verificationStatus = verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var normalizedEmailAddress: String {
        Self.normalizedAddress(emailAddress)
    }

    var isAcceptedForSending: Bool {
        if isPrimary { return true }

        guard let verificationStatus else {
            return isDefault
        }

        return verificationStatus.caseInsensitiveCompare("accepted") == .orderedSame
    }

    static func fromGmailSendAs(_ sendAs: SendAs) -> SendAsAlias? {
        let alias = SendAsAlias(
            emailAddress: sendAs.sendAsEmail,
            displayName: sendAs.displayName,
            isDefault: sendAs.isDefault == true,
            isPrimary: sendAs.isPrimary == true,
            verificationStatus: sendAs.verificationStatus
        )

        guard !alias.normalizedEmailAddress.isEmpty,
              alias.isAcceptedForSending else {
            return nil
        }

        return alias
    }

    static func validAliases(from sendAsList: [SendAs], accountEmail: String? = nil) -> [SendAsAlias] {
        var aliases = deduplicated(sendAsList.compactMap(Self.fromGmailSendAs))

        if let accountEmail,
           !accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !aliases.contains(where: { matches(accountEmail, alias: $0) }) {
            aliases.insert(
                SendAsAlias(
                    emailAddress: accountEmail,
                    isDefault: !aliases.contains(where: \.isDefault),
                    isPrimary: true,
                    verificationStatus: "accepted"
                ),
                at: 0
            )
        }

        return aliases
    }

    static func defaultAlias(in aliases: [SendAsAlias]) -> SendAsAlias? {
        aliases.first(where: \.isDefault) ??
            aliases.first(where: \.isPrimary) ??
            aliases.first
    }

    static func matches(_ rawAddress: String?, alias: SendAsAlias) -> Bool {
        guard let rawAddress else { return false }
        return normalizedAddress(rawAddress) == alias.normalizedEmailAddress
    }

    static func normalizedAddress(_ rawAddress: String) -> String {
        let extracted = EmailNormalizer.extractEmail(from: rawAddress) ?? rawAddress
        return extracted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func deduplicated(_ aliases: [SendAsAlias]) -> [SendAsAlias] {
        var aliasesByAddress: [String: SendAsAlias] = [:]
        var order: [String] = []

        for alias in aliases where alias.isAcceptedForSending {
            let key = alias.normalizedEmailAddress
            guard !key.isEmpty else { continue }

            if let existing = aliasesByAddress[key] {
                if shouldPrefer(alias, over: existing) {
                    aliasesByAddress[key] = alias
                }
            } else {
                aliasesByAddress[key] = alias
                order.append(key)
            }
        }

        return order.compactMap { aliasesByAddress[$0] }
    }

    private static func shouldPrefer(_ candidate: SendAsAlias, over existing: SendAsAlias) -> Bool {
        if candidate.isDefault != existing.isDefault {
            return candidate.isDefault
        }
        if candidate.isPrimary != existing.isPrimary {
            return candidate.isPrimary
        }
        if existing.displayName == nil, candidate.displayName != nil {
            return true
        }
        return false
    }
}

actor SendAsAliasManager {
    static let shared = SendAsAliasManager()

    private var cachedAliases: [SendAsAlias]?

    @discardableResult
    func setAliases(_ aliases: [SendAsAlias]) -> [SendAsAlias] {
        let validAliases = SendAsAlias.deduplicated(aliases)
        cachedAliases = validAliases
        return validAliases
    }

    func getAliases(from context: NSManagedObjectContext) async -> [SendAsAlias] {
        if let cachedAliases, !cachedAliases.isEmpty {
            return cachedAliases
        }

        let aliases = await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            guard let account = try? context.fetch(request).first else {
                return [SendAsAlias]()
            }

            let storedAliases = account.sendAsAliasesArray
            if !storedAliases.isEmpty {
                return storedAliases
            }

            let fallbackAliases = ([account.email] + account.aliasesArray).map {
                let isAccountEmail = $0.caseInsensitiveCompare(account.email) == .orderedSame
                return SendAsAlias(
                    emailAddress: $0,
                    isDefault: isAccountEmail,
                    isPrimary: isAccountEmail,
                    verificationStatus: "accepted"
                )
            }
            return SendAsAlias.deduplicated(fallbackAliases)
        }

        cachedAliases = aliases
        return aliases
    }

    func invalidate() {
        cachedAliases = nil
    }
}

struct EmailAddressListParser {
    static func addressTokens(from headerValue: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isInQuotes = false
        var angleDepth = 0
        var previousWasEscape = false

        for character in headerValue {
            if character == "\"" && !previousWasEscape {
                isInQuotes.toggle()
                current.append(character)
            } else if character == "<" && !isInQuotes {
                // Mailbox delimiters cannot nest. Restart at the newest '<'
                // so an unmatched display-name bracket cannot swallow later recipients.
                angleDepth = 1
                current.append(character)
            } else if character == ">" && !isInQuotes {
                angleDepth = max(0, angleDepth - 1)
                current.append(character)
            } else if character == "," && !isInQuotes && angleDepth == 0 {
                appendToken(current, to: &tokens)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }

            previousWasEscape = character == "\\" && !previousWasEscape
        }

        appendToken(current, to: &tokens)
        return tokens
    }

    static func emailAddresses(from headerValue: String) -> [String] {
        addressTokens(from: headerValue).compactMap { token in
            guard let email = EmailNormalizer.extractEmail(from: token) else { return nil }
            let normalized = SendAsAlias.normalizedAddress(email)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func appendToken(_ token: String, to tokens: inout [String]) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tokens.append(trimmed)
        }
    }
}

struct ReplyFromAddressResolution: Equatable, Sendable {
    let deliveredToAddress: String?
    let replyFromAddress: String?
}

struct ReplyFromAddressResolver {
    let sendAsAliases: [SendAsAlias]

    func resolve(headers: [MessageHeader], isSentMessage: Bool = false) -> ReplyFromAddressResolution {
        let validAliases = SendAsAlias.deduplicated(sendAsAliases)
        let defaultAlias = SendAsAlias.defaultAlias(in: validAliases)

        let directRecipientCandidates = recipientCandidates(for: ["to", "cc"], headers: headers)
        let senderAlias = isSentMessage ? firstMatchingAlias(
            in: recipientCandidates(for: ["from"], headers: headers),
            aliases: validAliases
        ) : nil
        if let senderAlias {
            return ReplyFromAddressResolution(
                deliveredToAddress: senderAlias.emailAddress,
                replyFromAddress: senderAlias.emailAddress
            )
        }

        let nonDefaultAliases = validAliases.filter { !$0.isDefault }
        if let matchedAlias = firstMatchingAlias(in: directRecipientCandidates, aliases: nonDefaultAliases) {
            return ReplyFromAddressResolution(
                deliveredToAddress: matchedAlias.emailAddress,
                replyFromAddress: matchedAlias.emailAddress
            )
        }

        var firstForwardingCandidate: String?
        for headerName in ["x-original-to", "envelope-to", "delivered-to"] {
            let candidates = recipientCandidates(for: [headerName], headers: headers)
            if firstForwardingCandidate == nil {
                firstForwardingCandidate = candidates.first
            }

            if let matchedAlias = firstMatchingAlias(in: candidates, aliases: validAliases) {
                return ReplyFromAddressResolution(
                    deliveredToAddress: matchedAlias.emailAddress,
                    replyFromAddress: matchedAlias.emailAddress
                )
            }
        }

        if let matchedAlias = firstMatchingAlias(in: directRecipientCandidates, aliases: validAliases) {
            return ReplyFromAddressResolution(
                deliveredToAddress: matchedAlias.emailAddress,
                replyFromAddress: matchedAlias.emailAddress
            )
        }

        if let firstForwardingCandidate {
            return ReplyFromAddressResolution(
                deliveredToAddress: firstForwardingCandidate,
                replyFromAddress: senderAlias?.emailAddress ?? defaultAlias?.emailAddress
            )
        }

        let fallbackAlias = senderAlias ?? defaultAlias
        return ReplyFromAddressResolution(
            deliveredToAddress: fallbackAlias?.emailAddress,
            replyFromAddress: fallbackAlias?.emailAddress
        )
    }

    private func recipientCandidates(for headerNames: Set<String>, headers: [MessageHeader]) -> [String] {
        headers
            .filter { headerNames.contains($0.name.lowercased()) }
            .flatMap { EmailAddressListParser.emailAddresses(from: $0.value) }
    }

    private func firstMatchingAlias(in candidates: [String], aliases: [SendAsAlias]) -> SendAsAlias? {
        for candidate in candidates {
            let normalizedCandidate = SendAsAlias.normalizedAddress(candidate)
            if let alias = aliases.first(where: { $0.normalizedEmailAddress == normalizedCandidate }) {
                return alias
            }
        }
        return nil
    }
}

struct ReplyFromAddressSelector {
    let sendAsAliases: [SendAsAlias]
    let fallbackEmail: String?
    let fallbackDisplayName: String?

    func select(replyFromAddress: String?, deliveredToAddress: String?) throws -> SendAsAlias {
        let validAliases = SendAsAlias.deduplicated(sendAsAliases)

        if let deliveredToAddress,
           !deliveredToAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           matchingAlias(for: deliveredToAddress, in: validAliases) == nil,
           matchingGmailEquivalentAlias(for: deliveredToAddress, in: validAliases) == nil,
           !matchesFallback(deliveredToAddress) {
            throw GmailSendService.SendError.sendAsAliasUnavailable(
                SendAsAlias.normalizedAddress(deliveredToAddress)
            )
        }

        if let replyFromAddress,
           let alias = matchingAlias(for: replyFromAddress, in: validAliases) {
            return alias
        }

        if let defaultAlias = SendAsAlias.defaultAlias(in: validAliases) {
            return defaultAlias
        }

        guard let fallbackEmail,
              !fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GmailSendService.SendError.authenticationFailed
        }

        return SendAsAlias(
            emailAddress: fallbackEmail,
            displayName: fallbackDisplayName,
            isDefault: true,
            isPrimary: true,
            verificationStatus: "accepted"
        )
    }

    private func matchingAlias(for address: String, in aliases: [SendAsAlias]) -> SendAsAlias? {
        let normalizedAddress = SendAsAlias.normalizedAddress(address)
        return aliases.first { $0.normalizedEmailAddress == normalizedAddress }
    }

    private func matchingGmailEquivalentAlias(for address: String, in aliases: [SendAsAlias]) -> SendAsAlias? {
        aliases.first { matchesGmailEquivalent(address, $0.normalizedEmailAddress) }
    }

    private func matchesFallback(_ address: String) -> Bool {
        guard let fallbackEmail else { return false }
        return SendAsAlias.normalizedAddress(address) == SendAsAlias.normalizedAddress(fallbackEmail)
            || matchesGmailEquivalent(address, fallbackEmail)
    }

    private func matchesGmailEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLHS = SendAsAlias.normalizedAddress(lhs)
        let normalizedRHS = SendAsAlias.normalizedAddress(rhs)
        guard EmailNormalizer.isGmailAddress(normalizedLHS),
              EmailNormalizer.isGmailAddress(normalizedRHS) else {
            return false
        }
        return EmailNormalizer.normalize(normalizedLHS) == EmailNormalizer.normalize(normalizedRHS)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
