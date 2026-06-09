import Foundation
import CoreData

/// Shared service for loading participant information from conversations
/// Eliminates duplicate logic between ConversationRowView and ChatView
@MainActor
final class ParticipantLoader {
    static let shared = ParticipantLoader()

    private struct ConversationParticipantSnapshot: Sendable {
        let emails: [String]
        let storedDisplayNamesByEmail: [String: String]
        let headerDisplayNamesByEmail: [String: String]
        let fallbackDisplayName: String?
        let participantHash: String?
    }

    private let currentUserAliasesProvider: ((NSManagedObjectContext?, String) async -> Set<String>)?
    private let rollupCache: ParticipantRollupCache
    private let resolver: ParticipantInfoResolver

    init(
        personCache: PersonCache = .shared,
        photoResolver: ProfilePhotoResolver = .shared,
        contactsResolver: any ContactsResolving = ContactsResolver.shared,
        currentUserAliasesProvider: ((NSManagedObjectContext?, String) async -> Set<String>)? = nil,
        prefetchDisplayNames: (@Sendable ([String]) async -> Void)? = nil,
        cachedDisplayNameProvider: (@Sendable (String) async -> String?)? = nil,
        photoLoader: (@Sendable ([String]) async -> [ProfilePhoto])? = nil,
        rollupDependencyTracker: any ParticipantRollupDependencyTracking = ParticipantRollupDependencyTracker.shared,
        participantRollupCacheTTL: TimeInterval = 300,
        maxParticipantRollupCacheEntries: Int = 600
    ) {
        self.currentUserAliasesProvider = currentUserAliasesProvider
        self.rollupCache = ParticipantRollupCache(
            rollupDependencyTracker: rollupDependencyTracker,
            participantRollupCacheTTL: participantRollupCacheTTL,
            maxParticipantRollupCacheEntries: maxParticipantRollupCacheEntries
        )
        self.resolver = ParticipantInfoResolver(
            personCache: personCache,
            photoResolver: photoResolver,
            contactsResolver: contactsResolver,
            prefetchDisplayNames: prefetchDisplayNames,
            cachedDisplayNameProvider: cachedDisplayNameProvider,
            photoLoader: photoLoader
        )
    }

    // MARK: - Public Types

    struct ParticipantInfo {
        let emails: [String]
        let displayNames: [String]
        let photos: [ProfilePhoto]
        let avatarDisplayNames: [String]
        let avatarPhotos: [ProfilePhoto?]
        let formattedDisplayName: String
        let totalUniqueParticipants: Int

        init(
            emails: [String],
            displayNames: [String],
            photos: [ProfilePhoto],
            formattedDisplayName: String,
            totalUniqueParticipants: Int,
            avatarDisplayNames: [String]? = nil,
            avatarPhotos: [ProfilePhoto?]? = nil
        ) {
            self.emails = emails
            self.displayNames = displayNames
            self.photos = photos
            self.avatarDisplayNames = avatarDisplayNames ?? displayNames
            self.avatarPhotos = avatarPhotos ?? photos.map(Optional.some)
            self.formattedDisplayName = formattedDisplayName
            self.totalUniqueParticipants = totalUniqueParticipants
        }
    }

    struct ResolvedParticipant: Equatable {
        let email: String
        let displayName: String
        let isRealDisplayName: Bool
        let contactIdentifier: String?
    }

    func cachedParticipantInfo(
        conversationObjectID: NSManagedObjectID,
        participantHash: String?,
        currentUserEmail: String,
        maxParticipants: Int = 4,
        fallbackDisplayName: String? = nil,
        includePhotos: Bool = true,
        headerDisplayNamesByEmail: [String: String]? = nil,
        evictOnTokenMismatch: Bool = false
    ) -> ParticipantInfo? {
        rollupCache.cachedParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: participantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants,
            fallbackDisplayName: fallbackDisplayName,
            includePhotos: includePhotos,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail,
            evictOnTokenMismatch: evictOnTokenMismatch
        )
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
        let currentUserAliases = await loadCurrentUserAliases(
            currentUserEmail: currentUserEmail,
            context: conversation.managedObjectContext
        )

        if let cachedInfo = cachedParticipantInfo(
            conversationObjectID: conversation.objectID,
            participantHash: conversation.participantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants,
            fallbackDisplayName: conversation.displayName,
            includePhotos: includePhotos,
            headerDisplayNamesByEmail: [:]
        ) {
            return cachedInfo
        }

        guard let context = conversation.managedObjectContext else {
            let participants = extractNonMeParticipants(
                from: conversation,
                currentUserEmail: currentUserEmail,
                currentUserAliases: currentUserAliases
            )

            return await buildAndCacheParticipantInfo(
                conversationObjectID: conversation.objectID,
                participantHash: conversation.participantHash,
                currentUserEmail: currentUserEmail,
                emails: participants,
                storedDisplayNamesByEmail: ConversationParticipantExtractor.participantDisplayNamesByEmail(from: conversation),
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
            participantHash: conversation.participantHash,
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
        participantHash: String? = nil,
        fallbackDisplayName: String? = nil,
        includePhotos: Bool = true
    ) async -> ParticipantInfo {
        let currentUserAliases = await loadCurrentUserAliases(
            currentUserEmail: currentUserEmail,
            context: context
        )

        if let cachedInfo = cachedParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: participantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants,
            fallbackDisplayName: fallbackDisplayName,
            includePhotos: includePhotos,
            headerDisplayNamesByEmail: [:]
        ) {
            return cachedInfo
        }

        if includePhotos,
           let upgradedCachedInfo = await rollupCache.upgradeCachedBaseParticipantInfoWithPhotos(
                conversationObjectID: conversationObjectID,
                participantHash: participantHash,
                currentUserEmail: currentUserEmail,
                maxParticipants: maxParticipants,
                fallbackDisplayName: fallbackDisplayName,
                headerDisplayNamesByEmail: [:],
                upgrade: resolver.upgradeParticipantInfoWithPhotos
           ) {
            return upgradedCachedInfo
        }

        let snapshot = await fetchConversationParticipantSnapshot(
            conversationObjectID: conversationObjectID,
            in: context,
            currentUserEmail: currentUserEmail,
            currentUserAliases: currentUserAliases,
            fallbackDisplayName: fallbackDisplayName
        )

        let effectiveParticipantHash = snapshot.participantHash ?? participantHash
        if let cachedInfo = cachedParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: effectiveParticipantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants,
            fallbackDisplayName: snapshot.fallbackDisplayName,
            includePhotos: includePhotos,
            headerDisplayNamesByEmail: snapshot.headerDisplayNamesByEmail,
            evictOnTokenMismatch: true
        ) {
            return cachedInfo
        }

        if includePhotos,
           let upgradedCachedInfo = await rollupCache.upgradeCachedBaseParticipantInfoWithPhotos(
                conversationObjectID: conversationObjectID,
                participantHash: effectiveParticipantHash,
                currentUserEmail: currentUserEmail,
                maxParticipants: maxParticipants,
                fallbackDisplayName: snapshot.fallbackDisplayName,
                headerDisplayNamesByEmail: snapshot.headerDisplayNamesByEmail,
                evictOnTokenMismatch: true,
                upgrade: resolver.upgradeParticipantInfoWithPhotos
           ) {
            return upgradedCachedInfo
        }

        return await buildAndCacheParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: effectiveParticipantHash,
            currentUserEmail: currentUserEmail,
            emails: snapshot.emails,
            storedDisplayNamesByEmail: snapshot.storedDisplayNamesByEmail,
            headerDisplayNamesByEmail: snapshot.headerDisplayNamesByEmail,
            fallbackDisplayName: snapshot.fallbackDisplayName,
            maxParticipants: maxParticipants,
            includePhotos: includePhotos
        )
    }

    /// Resolves stable sender grouping keys for chat bubble run collapsing.
    /// Emails that map to the same contact identifier share one grouping key.
    func senderGroupingKeys(for emails: [String]) async -> [String: String] {
        await resolver.senderGroupingKeys(for: emails)
    }

    /// Resolves display-ready participant records, deduplicating emails that belong to
    /// the same address book contact.
    func resolveParticipants(for emails: [String]) async -> [ResolvedParticipant] {
        await resolver.resolveParticipants(for: emails)
    }

    /// Extracts non-me participant emails from a conversation, deduplicated
    nonisolated
    func extractNonMeParticipants(
        from conversation: Conversation,
        currentUserEmail: String
    ) -> [String] {
        ConversationParticipantExtractor.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail,
            currentUserAliases: [currentUserEmail]
        )
    }

    nonisolated
    func extractNonMeParticipants(
        from conversation: Conversation,
        currentUserEmail: String,
        currentUserAliases: Set<String>
    ) -> [String] {
        ConversationParticipantExtractor.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail,
            currentUserAliases: currentUserAliases
        )
    }

    // MARK: - Private Helpers

    private func fetchConversationParticipantSnapshot(
        conversationObjectID: NSManagedObjectID,
        in context: NSManagedObjectContext,
        currentUserEmail: String,
        currentUserAliases: Set<String>,
        fallbackDisplayName: String?
    ) async -> ConversationParticipantSnapshot {
        await context.perform {
            guard let conversation = try? context.existingObject(with: conversationObjectID) as? Conversation,
                  !conversation.isDeleted else {
                return ConversationParticipantSnapshot(
                    emails: [],
                    storedDisplayNamesByEmail: [:],
                    headerDisplayNamesByEmail: [:],
                    fallbackDisplayName: fallbackDisplayName,
                    participantHash: nil
                )
            }

            let emails = ConversationParticipantExtractor.extractNonMeParticipants(
                from: conversation,
                currentUserEmail: currentUserEmail,
                currentUserAliases: currentUserAliases
            )

            return ConversationParticipantSnapshot(
                emails: emails,
                storedDisplayNamesByEmail: ConversationParticipantExtractor.participantDisplayNamesByEmail(from: conversation),
                headerDisplayNamesByEmail: ConversationParticipantExtractor.headerDisplayNamesByEmail(
                    in: context,
                    conversation: conversation,
                    participantEmails: emails
                ),
                fallbackDisplayName: conversation.displayName ?? fallbackDisplayName,
                participantHash: conversation.participantHash
            )
        }
    }

    private func buildAndCacheParticipantInfo(
        conversationObjectID: NSManagedObjectID,
        participantHash: String?,
        currentUserEmail: String,
        emails: [String],
        storedDisplayNamesByEmail: [String: String] = [:],
        headerDisplayNamesByEmail: [String: String] = [:],
        fallbackDisplayName: String?,
        maxParticipants: Int,
        includePhotos: Bool
    ) async -> ParticipantInfo {
        let baseInfo = await resolver.buildParticipantInfo(
            emails: emails,
            storedDisplayNamesByEmail: storedDisplayNamesByEmail,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail,
            fallbackDisplayName: fallbackDisplayName,
            maxParticipants: maxParticipants,
            includePhotos: false
        )

        let fullInfo: ParticipantInfo?
        if includePhotos {
            fullInfo = await resolver.upgradeParticipantInfoWithPhotos(baseInfo)
        } else {
            fullInfo = nil
        }

        rollupCache.cacheParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: participantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants,
            fallbackDisplayName: fallbackDisplayName,
            sourceEmails: emails,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail,
            baseInfo: baseInfo,
            fullInfo: fullInfo
        )

        return fullInfo ?? baseInfo
    }

    private func loadCurrentUserAliases(
        currentUserEmail: String,
        context: NSManagedObjectContext?
    ) async -> Set<String> {
        var aliases = ConversationParticipantExtractor.normalizedAliasSet(from: [currentUserEmail])

        if let currentUserAliasesProvider {
            aliases.formUnion(
                ConversationParticipantExtractor.normalizedAliasSet(
                    from: await currentUserAliasesProvider(context, currentUserEmail)
                )
            )
        } else if let context {
            aliases.formUnion(await AliasManager.shared.getAliases(from: context))
        } else {
            aliases.formUnion(await AliasManager.shared.getCachedAliases())
        }

        return aliases
    }

}
