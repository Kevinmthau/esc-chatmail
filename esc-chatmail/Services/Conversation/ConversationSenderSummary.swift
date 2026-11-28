import Foundation
import CoreData

/// What a conversation's stored title reads of its messages' senders: every
/// sender address, and each sanitized From name an address was given with
/// that name's newest occurrence. `ConversationRollupUpdater` builds it by
/// walking a small conversation's messages (`walking(_:)`), and
/// `ConversationRollupBoundedReader` from a grouped query for a large one
/// (architecture review 2026-11, data-model#4), so the title rule reads one
/// shape either way.
struct ConversationSenderSummary: Equatable {
    /// A name's newest occurrence: its date, then its message's ID, which
    /// orders names of one address whose newest dates are equal
    /// (`EmailNormalizer.resolveNewestFirstHeaderDisplayName`).
    struct Newest: Equatable {
        var date: Date
        var id: String
    }

    /// Normalized sender address to sanitized name to that name's newest
    /// occurrence.
    private(set) var candidatesByEmail: [String: [String: Newest]] = [:]
    /// Every normalized sender address, with or without a usable name.
    private(set) var senderEmails: Set<String> = []

    static func walking(_ messages: some Sequence<Message>) -> ConversationSenderSummary {
        var summary = ConversationSenderSummary()
        for message in messages {
            summary.add(
                senderEmail: message.senderEmail,
                senderName: message.senderName,
                date: message.internalDate,
                id: message.id
            )
        }
        return summary
    }

    /// Adds one message's sender. Returns the address and sanitized name it
    /// recorded a candidate under, nil when the message gave no usable name.
    @discardableResult
    mutating func add(senderEmail: String?, senderName: String?, date: Date, id: String) -> (email: String, name: String)? {
        guard let senderEmail else { return nil }
        let normalizedEmail = EmailNormalizer.normalize(senderEmail)
        guard !normalizedEmail.isEmpty else { return nil }
        senderEmails.insert(normalizedEmail)
        guard let displayName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            senderName,
            forEmail: normalizedEmail
        ) else {
            return nil
        }
        record(Newest(date: date, id: id), email: normalizedEmail, name: displayName)
        return (normalizedEmail, displayName)
    }

    /// Records a candidate already normalized and sanitized, if it is newer
    /// than the one held for that address and name.
    mutating func record(_ candidate: Newest, email: String, name: String) {
        senderEmails.insert(email)
        if let newest = candidatesByEmail[email]?[name], !Self.isNewer(candidate, than: newest) {
            return
        }
        candidatesByEmail[email, default: [:]][name] = candidate
    }

    /// Folds `other` in: its addresses, and each of its candidates that is
    /// newer than the one held.
    mutating func merge(_ other: ConversationSenderSummary) {
        senderEmails.formUnion(other.senderEmails)
        for (email, candidates) in other.candidatesByEmail {
            for (name, newest) in candidates {
                record(newest, email: email, name: name)
            }
        }
    }

    static func isNewer(_ candidate: Newest, than other: Newest) -> Bool {
        candidate.date > other.date || (candidate.date == other.date && candidate.id > other.id)
    }

    /// The header name the title uses for each sender address: newest first,
    /// an older, fuller variant of the same name still upgrading it
    /// (`EmailNormalizer.mergeNewestFirstHeaderDisplayName`).
    var headerDisplayNamesByEmail: [String: String] {
        var displayNames: [String: String] = [:]
        for (email, candidates) in candidatesByEmail {
            let ranked = candidates.map { name, newest in
                EmailNormalizer.HeaderDisplayNameCandidate(
                    displayName: name,
                    newestInternalDate: newest.date,
                    newestMessageID: newest.id
                )
            }
            if let winner = EmailNormalizer.resolveNewestFirstHeaderDisplayName(from: ranked, forEmail: email) {
                displayNames[email] = winner
            }
        }
        return displayNames
    }
}
