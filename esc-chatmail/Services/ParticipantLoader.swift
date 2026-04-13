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
    private let contactsResolver: any ContactsResolving
    private let prefetchDisplayNames: (@Sendable ([String]) async -> Void)?
    private let cachedDisplayNameProvider: (@Sendable (String) async -> String?)?
    private let photoLoader: (@Sendable ([String]) async -> [ProfilePhoto])?

    init(
        personCache: PersonCache = .shared,
        photoResolver: ProfilePhotoResolver = .shared,
        contactsResolver: any ContactsResolving = ContactsResolver.shared,
        prefetchDisplayNames: (@Sendable ([String]) async -> Void)? = nil,
        cachedDisplayNameProvider: (@Sendable (String) async -> String?)? = nil,
        photoLoader: (@Sendable ([String]) async -> [ProfilePhoto])? = nil
    ) {
        self.personCache = personCache
        self.photoResolver = photoResolver
        self.contactsResolver = contactsResolver
        self.prefetchDisplayNames = prefetchDisplayNames
        self.cachedDisplayNameProvider = cachedDisplayNameProvider
        self.photoLoader = photoLoader
    }

    // MARK: - Public Types

    struct ParticipantInfo {
        let emails: [String]
        let displayNames: [String]
        let photos: [ProfilePhoto]
        let formattedDisplayName: String
        let totalUniqueParticipants: Int
    }

    struct ResolvedParticipant: Equatable {
        let email: String
        let displayName: String
        let contactIdentifier: String?
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
        maxParticipants: Int = 4,
        includePhotos: Bool = true
    ) async -> ParticipantInfo {
        guard let context = conversation.managedObjectContext else {
            let participants = extractNonMeParticipants(
                from: conversation,
                currentUserEmail: currentUserEmail
            )

            return await buildParticipantInfo(
                emails: participants,
                fallbackDisplayName: conversation.displayName,
                maxParticipants: maxParticipants,
                includePhotos: includePhotos
            )
        }

        return await loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants,
            fallbackDisplayName: conversation.displayName,
            includePhotos: includePhotos
        )
    }

    /// Loads participant info via objectID lookup so callers can avoid retaining a live
    /// NSManagedObject across async boundaries while sync/cleanup may merge or delete it.
    func loadParticipants(
        from conversationObjectID: NSManagedObjectID,
        in context: NSManagedObjectContext,
        currentUserEmail: String,
        maxParticipants: Int = 4,
        fallbackDisplayName: String? = nil,
        includePhotos: Bool = true
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
            maxParticipants: maxParticipants,
            includePhotos: includePhotos
        )
    }

    /// Resolves stable sender grouping keys for chat bubble run collapsing.
    /// Emails that map to the same contact identifier share one grouping key.
    func senderGroupingKeys(for emails: [String]) async -> [String: String] {
        guard !emails.isEmpty else { return [:] }

        var uniqueNormalizedEmails: [String] = []
        var seenEmails = Set<String>()

        for email in emails {
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty,
                  !seenEmails.contains(normalizedEmail) else { continue }

            seenEmails.insert(normalizedEmail)
            uniqueNormalizedEmails.append(normalizedEmail)
        }

        var groupingKeys: [String: String] = [:]
        for normalizedEmail in uniqueNormalizedEmails {
            if let contactIdentifier = await contactsResolver.lookup(email: normalizedEmail)?.contactIdentifier,
               !contactIdentifier.isEmpty {
                groupingKeys[normalizedEmail] = "contact:\(contactIdentifier)"
            } else {
                groupingKeys[normalizedEmail] = "email:\(normalizedEmail)"
            }
        }

        return groupingKeys
    }

    /// Resolves display-ready participant records, deduplicating emails that belong to
    /// the same address book contact.
    func resolveParticipants(for emails: [String]) async -> [ResolvedParticipant] {
        guard !emails.isEmpty else { return [] }

        await prefetchNamesIfNeeded(for: emails)

        var resolvedParticipants: [ResolvedParticipant] = []
        var seenParticipantKeys = Set<String>()

        for email in emails {
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty else { continue }

            let match = await contactsResolver.lookup(email: email)
            let participantKey: String
            if let contactIdentifier = match?.contactIdentifier,
               !contactIdentifier.isEmpty {
                participantKey = "contact:\(contactIdentifier)"
            } else {
                participantKey = "email:\(normalizedEmail)"
            }

            guard seenParticipantKeys.insert(participantKey).inserted else { continue }

            resolvedParticipants.append(
                ResolvedParticipant(
                    email: email,
                    displayName: await resolveDisplayName(for: email, match: match),
                    contactIdentifier: match?.contactIdentifier
                )
            )
        }

        return resolvedParticipants
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
        maxParticipants: Int,
        includePhotos: Bool
    ) async -> ParticipantInfo {
        let resolvedParticipants = await resolveParticipants(for: emails)
        let topParticipants = Array(resolvedParticipants.prefix(maxParticipants))
        let displayNames = topParticipants.map(\.displayName)
        let formattedName = DisplayNameFormatter.formatForRow(
            names: displayNames,
            totalCount: resolvedParticipants.count,
            fallback: fallbackDisplayName
        )
        let photos = includePhotos ? await loadPhotos(for: topParticipants.map(\.email)) : []

        return ParticipantInfo(
            emails: topParticipants.map(\.email),
            displayNames: displayNames,
            photos: photos,
            formattedDisplayName: formattedName,
            totalUniqueParticipants: resolvedParticipants.count
        )
    }

    private func prefetchNamesIfNeeded(for emails: [String]) async {
        if let prefetchDisplayNames {
            await prefetchDisplayNames(emails)
            return
        }

        // Prefetch all emails - the cache will filter internally
        await personCache.prefetch(emails: emails)
    }

    private func resolveDisplayName(for email: String, match: ContactMatch?) async -> String {
        let trimmedContactName = match?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedContactName, !trimmedContactName.isEmpty {
            return trimmedContactName
        }

        let cachedName: String?
        if let cachedDisplayNameProvider {
            cachedName = await cachedDisplayNameProvider(email)
        } else {
            cachedName = await personCache.getCachedDisplayName(for: email)
        }
        let trimmedCachedName = cachedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCachedName, !trimmedCachedName.isEmpty {
            return trimmedCachedName
        }

        return fallbackDisplayName(for: email)
    }

    private func fallbackDisplayName(for email: String) -> String {
        EmailNormalizer.formatAsDisplayName(email: email)
    }

    private func loadPhotos(for emails: [String]) async -> [ProfilePhoto] {
        if let photoLoader {
            return await photoLoader(emails)
        }

        let photoResults = await photoResolver.resolvePhotos(for: emails)
        return emails.compactMap { email in
            photoResults[EmailNormalizer.normalize(email)]
        }
    }

}
