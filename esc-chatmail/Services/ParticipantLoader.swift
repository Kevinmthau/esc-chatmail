import Foundation
import CoreData

/// Shared service for loading participant information from conversations
/// Eliminates duplicate logic between ConversationRowView and ChatView
@MainActor
final class ParticipantLoader {
    static let shared = ParticipantLoader()

    private let personCache = PersonCache.shared
    private let photoResolver = ProfilePhotoResolver.shared

    private init() {}

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
        let participants = extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail
        )

        let topParticipants = Array(participants.prefix(maxParticipants))

        // Prefetch names if needed
        await prefetchNamesIfNeeded(for: topParticipants)

        // Resolve display names
        let displayNames = await resolveDisplayNames(for: topParticipants)

        // Format the display name for UI
        let formattedName = DisplayNameFormatter.formatForRow(
            names: displayNames,
            totalCount: participants.count,
            fallback: conversation.displayName
        )

        // Load photos (may involve network)
        let photos = await loadPhotos(for: topParticipants)

        return ParticipantInfo(
            emails: topParticipants,
            displayNames: displayNames,
            photos: photos,
            formattedDisplayName: formattedName
        )
    }

    /// Extracts non-me participant emails from a conversation, deduplicated
    func extractNonMeParticipants(
        from conversation: Conversation,
        currentUserEmail: String
    ) -> [String] {
        guard let participants = conversation.participants else { return [] }

        let normalizedMyEmail = EmailNormalizer.normalize(currentUserEmail)
        var seenEmails = Set<String>()
        var result: [String] = []

        for participant in participants {
            guard let email = participant.person?.email else { continue }
            let normalized = EmailNormalizer.normalize(email)

            guard normalized != normalizedMyEmail,
                  !seenEmails.contains(normalized) else { continue }

            seenEmails.insert(normalized)
            result.append(email)
        }

        return result
    }

    // MARK: - Private Helpers

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
