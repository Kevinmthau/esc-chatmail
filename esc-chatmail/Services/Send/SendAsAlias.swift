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
    /// Bumped by `invalidate()`: a load suspended in Core Data when the cache was
    /// invalidated (a sign-in over another account's store resets the store between the
    /// read and the write) returns what it read and caches nothing, as `AliasManager`'s
    /// does (architecture review 2026-11, account-boundary-auth#2).
    private var invalidationEpoch: UInt64 = 0

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

        let epoch = invalidationEpoch
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

        guard epoch == invalidationEpoch else {
            // Invalidated while the load was suspended: answer, cache nothing.
            return aliases
        }
        cachedAliases = aliases
        return aliases
    }

    func invalidate() {
        invalidationEpoch &+= 1
        cachedAliases = nil
    }
}

struct EmailAddressListParser {
    /// Splits an address header into one token per mailbox, at every comma
    /// outside a quoted string, a comment and an angle-addr.
    ///
    /// Comments are skipped as RFC 5322 has them, nested, in the phrase and
    /// inside the angle-addr: a comma inside one does not end the mailbox.
    /// Splitting there made the text before it a mailbox of its own, so
    /// `(<boss@corp.example>, x) <x@attacker.example>` (one mailbox, whose
    /// address is x@attacker.example) read as boss@corp.example first. Inside
    /// the angle-addr a domain literal (`[…]`) and a quoted local part are
    /// text too. A backslash escapes only inside a quoted string, a comment or
    /// a domain literal. A comment that never closes runs to the end, as a
    /// quote that never closes always has. Read as Unicode scalars, for the
    /// reason `EmailNormalizer.mailboxAddress(inToken:)` gives; its scanner
    /// reads quotes, comments, literals and escapes by these same rules, and
    /// so does the web app's port (`web/src/identity/normalizeEmail.ts`).
    static func addressTokens(from headerValue: String) -> [String] {
        addressTokenRanges(from: headerValue).map { String(headerValue.unicodeScalars[$0]) }
    }

    /// Where each of `addressTokens(from:)`'s tokens sits in `headerValue`,
    /// trimmed of whitespace, empty tokens left out.
    static func addressTokenRanges(from headerValue: String) -> [Range<String.Index>] {
        enum Mode { case phrase, quote, comment, angle, angleQuote, angleComment, domainLiteral, phraseLiteral }
        let scalars = headerValue.unicodeScalars
        var ranges: [Range<String.Index>] = []
        var tokenStart = scalars.startIndex
        var mode = Mode.phrase
        var commentDepth = 0
        var previousWasEscape = false
        // As in `EmailNormalizer.scanMailbox`: a `[` right after an `@` in
        // the phrase opens a bare address's domain literal.
        var lastPhraseScalar: Unicode.Scalar?

        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let isEscaped = previousWasEscape
            var escapes = false
            var splitsHere = false
            switch mode {
            case .phrase:
                if scalar == "\"" {
                    mode = .quote
                } else if scalar == "(" {
                    mode = .comment
                    commentDepth = 1
                } else if scalar == "[" && lastPhraseScalar == "@" {
                    mode = .phraseLiteral
                } else if scalar == "<" {
                    mode = .angle
                } else if scalar == "," {
                    splitsHere = true
                    lastPhraseScalar = nil
                }
                if !splitsHere && (mode == .phrase || mode == .angle)
                    && !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    lastPhraseScalar = scalar
                }
            case .quote:
                escapes = true
                if scalar == "\"" && !isEscaped {
                    mode = .phrase
                }
            case .comment, .angleComment:
                escapes = true
                if scalar == "(" && !isEscaped {
                    commentDepth += 1
                } else if scalar == ")" && !isEscaped {
                    commentDepth -= 1
                    if commentDepth == 0 {
                        mode = mode == .comment ? .phrase : .angle
                    }
                }
            case .angle:
                // Mailbox delimiters cannot nest: a nested '<' restarts the
                // angle-addr, so an unmatched display-name bracket cannot
                // swallow later recipients.
                if scalar == "\"" {
                    mode = .angleQuote
                } else if scalar == "(" {
                    mode = .angleComment
                    commentDepth = 1
                } else if scalar == "[" {
                    mode = .domainLiteral
                } else if scalar == ">" {
                    mode = .phrase
                }
            case .angleQuote:
                escapes = true
                if scalar == "\"" && !isEscaped {
                    mode = .angle
                }
            case .domainLiteral:
                escapes = true
                if scalar == "]" && !isEscaped {
                    mode = .angle
                }
            case .phraseLiteral:
                escapes = true
                if scalar == "]" && !isEscaped {
                    mode = .phrase
                }
            }

            let next = scalars.index(after: index)
            if splitsHere {
                appendTrimmedRange(tokenStart..<index, of: scalars, to: &ranges)
                tokenStart = next
            }
            previousWasEscape = escapes && scalar == "\\" && !isEscaped
            index = next
        }

        appendTrimmedRange(tokenStart..<scalars.endIndex, of: scalars, to: &ranges)
        return ranges
    }

    /// Every mailbox in an address header value, with its normalized address
    /// and its display name: how a message's From, To, Cc and Bcc are read
    /// for its rows and for its conversation's participant hash.
    static func mailboxes(from headerValue: String) -> [EmailAddress] {
        let tokens = addressTokens(from: headerValue)
        return tokens.compactMap { token in
            guard let match = EmailNormalizer.mailboxAddress(inToken: token, isOnlyMailbox: tokens.count == 1) else {
                return nil
            }
            return EmailAddress(
                email: EmailNormalizer.normalize(match.email),
                displayName: EmailNormalizer.displayName(inToken: token, match: match)
            )
        }
    }

    static func emailAddresses(from headerValue: String) -> [String] {
        addressTokens(from: headerValue).compactMap { token in
            guard let email = EmailNormalizer.extractEmail(from: token) else { return nil }
            let normalized = SendAsAlias.normalizedAddress(email)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func appendTrimmedRange(
        _ range: Range<String.Index>,
        of scalars: String.UnicodeScalarView,
        to ranges: inout [Range<String.Index>]
    ) {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, CharacterSet.whitespacesAndNewlines.contains(scalars[lower]) {
            lower = scalars.index(after: lower)
        }
        while lower < upper, CharacterSet.whitespacesAndNewlines.contains(scalars[scalars.index(before: upper)]) {
            upper = scalars.index(before: upper)
        }
        if lower < upper {
            ranges.append(lower..<upper)
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
