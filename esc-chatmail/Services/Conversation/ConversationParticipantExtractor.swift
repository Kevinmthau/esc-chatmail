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

        // Newest-first so the most recent From header wins; an older, fuller
        // variant of the same name may still upgrade it (see
        // EmailNormalizer.mergeNewestFirstHeaderDisplayName).
        let request = NSFetchRequest<NSDictionary>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["senderEmail", "senderName", "internalDate"]
        request.predicate = NSPredicate(
            format: "conversation == %@ AND senderEmail != nil AND senderName != nil",
            conversation
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        request.fetchBatchSize = 50

        let rows: [NSDictionary]
        do {
            rows = try context.fetch(request)
        } catch {
            Log.error("Failed to fetch message header display names", category: .coreData, error: error)
            return [:]
        }

        var displayNames: [String: String] = [:]
        for row in rows {
            guard let senderEmail = row["senderEmail"] as? String else { continue }
            let normalizedEmail = EmailNormalizer.normalize(senderEmail)
            guard participantEmailSet.contains(normalizedEmail),
                  let displayName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                    row["senderName"] as? String,
                    forEmail: normalizedEmail
                  ) else {
                continue
            }

            displayNames[normalizedEmail] = EmailNormalizer.mergeNewestFirstHeaderDisplayName(
                displayName,
                into: displayNames[normalizedEmail],
                forEmail: normalizedEmail
            )
        }

        return displayNames
    }
}
