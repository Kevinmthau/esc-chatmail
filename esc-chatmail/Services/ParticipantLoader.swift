import Foundation
import CoreData

/// Shared service for loading participant information from conversations
/// Eliminates duplicate logic between ConversationRowView and ChatView
@MainActor
final class ParticipantLoader {
    static let shared = ParticipantLoader()

    private struct ConversationParticipantSnapshot: Sendable {
        let emails: [String]
        let fallbackDisplayName: String?
    }

    private let personCache: PersonCache
    private let photoResolver: ProfilePhotoResolver

    init(
        personCache: PersonCache = .shared,
        photoResolver: ProfilePhotoResolver = .shared
    ) {
        self.personCache = personCache
        self.photoResolver = photoResolver
    }

    // MARK: - Public Types

    struct ParticipantInfo {
        let emails: [String]
        let displayNames: [String]
        let photos: [ProfilePhoto]
        let formattedDisplayName: String
    }

    // MARK: - Public API

    /// Loads participant info for a conversation, excluding the current user
    /// - Parameters:
    ///   - conversation: The conversation to load participants from
    ///   - currentUserEmail: The current user's email to exclude
    ///   - maxParticipants: Maximum number of participants to load (default 4 for avatar display)
    /// - Returns: ParticipantInfo with resolved names and photos
    func loadParticipants(
        from conversation: Conversation,
        currentUserEmail: String,
        maxParticipants: Int = 4
    ) async -> ParticipantInfo {
        guard let context = conversation.managedObjectContext else {
            let participants = extractNonMeParticipants(
                from: conversation,
                currentUserEmail: currentUserEmail
            )

            return await buildParticipantInfo(
                emails: participants,
                fallbackDisplayName: conversation.displayName,
                maxParticipants: maxParticipants
            )
        }

        return await loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants,
            fallbackDisplayName: conversation.displayName
        )
    }

    /// Loads participant info via objectID lookup so callers can avoid retaining a live
    /// NSManagedObject across async boundaries while sync/cleanup may merge or delete it.
    func loadParticipants(
        from conversationObjectID: NSManagedObjectID,
        in context: NSManagedObjectContext,
        currentUserEmail: String,
        maxParticipants: Int = 4,
        fallbackDisplayName: String? = nil
    ) async -> ParticipantInfo {
        let snapshot = await fetchConversationParticipantSnapshot(
            conversationObjectID: conversationObjectID,
            in: context,
            currentUserEmail: currentUserEmail,
            fallbackDisplayName: fallbackDisplayName
        )

        return await buildParticipantInfo(
            emails: snapshot.emails,
            fallbackDisplayName: snapshot.fallbackDisplayName,
            maxParticipants: maxParticipants
        )
    }

    /// Extracts non-me participant emails from a conversation, deduplicated
    nonisolated
    func extractNonMeParticipants(
        from conversation: Conversation,
        currentUserEmail: String
    ) -> [String] {
        Self.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail
        )
    }

    nonisolated
    private static func extractNonMeParticipants(
        from conversation: Conversation,
        currentUserEmail: String
    ) -> [String] {
        guard let participants = conversation.participants else { return [] }

        let normalizedMyEmail = EmailNormalizer.normalize(currentUserEmail)
        var seenEmails = Set<String>()
        var result: [String] = []

        for participant in participants {
            guard let person = participant.person else { continue }
            if EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                continue
            }

            let email = person.email
            let normalized = EmailNormalizer.normalize(email)

            guard normalized != normalizedMyEmail,
                  !seenEmails.contains(normalized) else { continue }

            seenEmails.insert(normalized)
            result.append(email)
        }

        return result
    }

    // MARK: - Private Helpers

    private func fetchConversationParticipantSnapshot(
        conversationObjectID: NSManagedObjectID,
        in context: NSManagedObjectContext,
        currentUserEmail: String,
        fallbackDisplayName: String?
    ) async -> ConversationParticipantSnapshot {
        await context.perform {
            guard let conversation = try? context.existingObject(with: conversationObjectID) as? Conversation,
                  !conversation.isDeleted else {
                return ConversationParticipantSnapshot(
                    emails: [],
                    fallbackDisplayName: fallbackDisplayName
                )
            }

            return ConversationParticipantSnapshot(
                emails: Self.extractNonMeParticipants(
                    from: conversation,
                    currentUserEmail: currentUserEmail
                ),
                fallbackDisplayName: conversation.displayName ?? fallbackDisplayName
            )
        }
    }

    private func buildParticipantInfo(
        emails: [String],
        fallbackDisplayName: String?,
        maxParticipants: Int
    ) async -> ParticipantInfo {
        let topParticipants = Array(emails.prefix(maxParticipants))

        await prefetchNamesIfNeeded(for: topParticipants)

        let displayNames = await resolveDisplayNames(for: topParticipants)
        let formattedName = DisplayNameFormatter.formatForRow(
            names: displayNames,
            totalCount: emails.count,
            fallback: fallbackDisplayName
        )
        let photos = await loadPhotos(for: topParticipants)

        return ParticipantInfo(
            emails: topParticipants,
            displayNames: displayNames,
            photos: photos,
            formattedDisplayName: formattedName
        )
    }

    private func prefetchNamesIfNeeded(for emails: [String]) async {
        // Prefetch all emails - the cache will filter internally
        await personCache.prefetch(emails: emails)
    }

    private func resolveDisplayNames(for emails: [String]) async -> [String] {
        var names: [String] = []
        for email in emails {
            if let cached = await personCache.getCachedDisplayName(for: email) {
                names.append(cached)
            } else {
                names.append(fallbackDisplayName(for: email))
            }
        }
        return names
    }

    private func fallbackDisplayName(for email: String) -> String {
        EmailNormalizer.formatAsDisplayName(email: email)
    }

    private func loadPhotos(for emails: [String]) async -> [ProfilePhoto] {
        let photoResults = await photoResolver.resolvePhotos(for: emails)
        return emails.compactMap { email in
            photoResults[EmailNormalizer.normalize(email)]
        }
    }

}
