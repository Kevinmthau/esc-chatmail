import Foundation
import CoreData

/// Reads participant data out of a `Conversation`'s Core Data graph: the
/// deduplicated non-me participant emails, the per-email stored display names,
/// the best per-email header (message-sender) display names, and the normalized
/// self-alias set used to exclude the current user.
///
/// Extracted from `ParticipantLoader` so the Core Data parsing lives in one
/// focused, independently testable unit, separate from the loader's caching and
/// async resolution. All entry points are non-isolated static functions over the
/// passed-in objects/context, so they run safely inside a `context.perform` block.
enum ConversationParticipantExtractor {
    static func extractNonMeParticipants(
        from conversation: Conversation,
        currentUserEmail: String,
        currentUserAliases: Set<String>
    ) -> [String] {
        guard let participants = conversation.participants else { return [] }

        var normalizedSelfAliases = normalizedAliasSet(from: currentUserAliases)
        let normalizedMyEmail = EmailNormalizer.normalize(currentUserEmail)
        if !normalizedMyEmail.isEmpty {
            normalizedSelfAliases.insert(normalizedMyEmail)
        }

        var seenEmails = Set<String>()
        var result: [String] = []

        for participant in participants {
            guard let person = participant.person else { continue }
            if EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                continue
            }

            let email = person.email
            let normalized = EmailNormalizer.normalize(email)

            guard !normalized.isEmpty,
                  !normalizedSelfAliases.contains(normalized),
                  !seenEmails.contains(normalized) else { continue }

            seenEmails.insert(normalized)
            result.append(email)
        }

        return result
    }

    static func participantDisplayNamesByEmail(from conversation: Conversation) -> [String: String] {
        guard let participants = conversation.participants else { return [:] }

        var displayNames: [String: String] = [:]
        for participant in participants {
            guard let person = participant.person else { continue }
            let normalizedEmail = EmailNormalizer.normalize(person.email)
            guard !normalizedEmail.isEmpty,
                  let displayName = person.displayName,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            displayNames[normalizedEmail] = displayName
        }

        return displayNames
    }

    static func normalizedAliasSet(from aliases: some Sequence<String>) -> Set<String> {
        Set(
            aliases
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
    }

    static func headerDisplayNamesByEmail(
        in context: NSManagedObjectContext,
        conversation: Conversation,
        participantEmails: [String]
    ) -> [String: String] {
        let participantEmailSet = Set(
            participantEmails
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
        guard !participantEmailSet.isEmpty else { return [:] }

        // Fetch distinct (senderEmail, senderName) header pairs, not one row
        // per message: dictionary fetches ignore fetchBatchSize, so a per-row
        // fetch materializes an NSDictionary for every message of the thread
        // on the caller's queue — the main-queue view context when list rows
        // load. The name signal only needs each distinct pair; DISTINCT keeps
        // the per-message work inside SQLite. (In-memory stores ignore
        // returnsDistinctResults and return per-row duplicates; the Set below
        // dedupes either way.)
        let request = NSFetchRequest<NSDictionary>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["senderEmail", "senderName"]
        request.returnsDistinctResults = true
        request.predicate = NSPredicate(
            format: "conversation == %@ AND senderEmail != nil AND senderName != nil",
            conversation
        )

        let rows: [NSDictionary]
        do {
            rows = try context.fetch(request)
        } catch {
            Log.error("Failed to fetch message header display names", category: .coreData, error: error)
            return [:]
        }

        var rawPairs = Set<RawHeaderPair>()
        for row in rows {
            guard let senderEmail = row["senderEmail"] as? String,
                  let senderName = row["senderName"] as? String else { continue }
            rawPairs.insert(RawHeaderPair(senderEmail: senderEmail, senderName: senderName))
        }

        // Group raw pairs into sanitized name candidates per normalized email.
        // Several raw pairs can collapse into one candidate (address case
        // variants, whitespace in the name).
        var rawPairsByCandidate: [String: [String: [RawHeaderPair]]] = [:]
        for pair in rawPairs {
            let normalizedEmail = EmailNormalizer.normalize(pair.senderEmail)
            guard participantEmailSet.contains(normalizedEmail),
                  let displayName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                    pair.senderName,
                    forEmail: normalizedEmail
                  ) else {
                continue
            }
            rawPairsByCandidate[normalizedEmail, default: [:]][displayName, default: []].append(pair)
        }

        var displayNames: [String: String] = [:]
        for (email, candidates) in rawPairsByCandidate {
            if candidates.count == 1, let onlyName = candidates.keys.first {
                displayNames[email] = onlyName
                continue
            }

            // Contested: the sender used several distinct names (a rebrand).
            // Newest-first so the most recent From header wins; an older,
            // fuller variant of the same name may still upgrade it (see
            // EmailNormalizer.mergeNewestFirstHeaderDisplayName). Each
            // candidate's rank is its newest occurrence across its raw pairs,
            // resolved with fetchLimit-1 lookups so the (rare) contested case
            // still avoids materializing the whole thread.
            let ranked = candidates.compactMap { name, pairs -> EmailNormalizer.HeaderDisplayNameCandidate? in
                var newest: (date: Date, id: String)?
                for pair in pairs {
                    guard let occurrence = newestOccurrence(of: pair, in: conversation, context: context) else {
                        continue
                    }
                    if newest == nil
                        || occurrence.date > newest!.date
                        || (occurrence.date == newest!.date && occurrence.id > newest!.id) {
                        newest = occurrence
                    }
                }
                guard let newest else { return nil }
                return EmailNormalizer.HeaderDisplayNameCandidate(
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

    private struct RawHeaderPair: Hashable {
        let senderEmail: String
        let senderName: String
    }

    /// The newest (internalDate, id) of the messages carrying one exact raw
    /// header pair, matching the ordering a full newest-first scan would see.
    private static func newestOccurrence(
        of pair: RawHeaderPair,
        in conversation: Conversation,
        context: NSManagedObjectContext
    ) -> (date: Date, id: String)? {
        let request = NSFetchRequest<NSDictionary>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["internalDate", "id"]
        request.predicate = NSPredicate(
            format: "conversation == %@ AND senderEmail == %@ AND senderName == %@",
            conversation,
            pair.senderEmail,
            pair.senderName
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        request.fetchLimit = 1

        let rows: [NSDictionary]
        do {
            rows = try context.fetch(request)
        } catch {
            Log.error("Failed to fetch newest header name occurrence", category: .coreData, error: error)
            return nil
        }

        guard let row = rows.first,
              let date = row["internalDate"] as? Date,
              let id = row["id"] as? String else {
            return nil
        }
        return (date, id)
    }
}
