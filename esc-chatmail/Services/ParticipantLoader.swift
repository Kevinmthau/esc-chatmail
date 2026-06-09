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

    private let personCache: PersonCache
    private let photoResolver: ProfilePhotoResolver
    private let contactsResolver: any ContactsResolving
    private let currentUserAliasesProvider: ((NSManagedObjectContext?, String) async -> Set<String>)?
    private let prefetchDisplayNames: (@Sendable ([String]) async -> Void)?
    private let cachedDisplayNameProvider: (@Sendable (String) async -> String?)?
    private let photoLoader: (@Sendable ([String]) async -> [ProfilePhoto])?
    private let rollupCache: ParticipantRollupCache

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
        self.personCache = personCache
        self.photoResolver = photoResolver
        self.contactsResolver = contactsResolver
        self.currentUserAliasesProvider = currentUserAliasesProvider
        self.prefetchDisplayNames = prefetchDisplayNames
        self.cachedDisplayNameProvider = cachedDisplayNameProvider
        self.photoLoader = photoLoader
        self.rollupCache = ParticipantRollupCache(
            rollupDependencyTracker: rollupDependencyTracker,
            participantRollupCacheTTL: participantRollupCacheTTL,
            maxParticipantRollupCacheEntries: maxParticipantRollupCacheEntries
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
                upgrade: upgradeParticipantInfoWithPhotos
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
                upgrade: upgradeParticipantInfoWithPhotos
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
        await resolveParticipants(
            for: emails,
            storedDisplayNamesByEmail: [:],
            headerDisplayNamesByEmail: [:]
        )
    }

    private func resolveParticipants(
        for emails: [String],
        storedDisplayNamesByEmail: [String: String],
        headerDisplayNamesByEmail: [String: String]
    ) async -> [ResolvedParticipant] {
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

            let resolvedDisplayName = await resolveDisplayName(
                for: email,
                match: match,
                storedDisplayName: storedDisplayNamesByEmail[normalizedEmail],
                headerDisplayName: headerDisplayNamesByEmail[normalizedEmail]
            )
            resolvedParticipants.append(
                ResolvedParticipant(
                    email: email,
                    displayName: resolvedDisplayName.name,
                    isRealDisplayName: resolvedDisplayName.isReal,
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
        let baseInfo = await buildParticipantInfo(
            emails: emails,
            storedDisplayNamesByEmail: storedDisplayNamesByEmail,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail,
            fallbackDisplayName: fallbackDisplayName,
            maxParticipants: maxParticipants,
            includePhotos: false
        )

        let fullInfo: ParticipantInfo?
        if includePhotos {
            fullInfo = await upgradeParticipantInfoWithPhotos(baseInfo)
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

    private func buildParticipantInfo(
        emails: [String],
        storedDisplayNamesByEmail: [String: String],
        headerDisplayNamesByEmail: [String: String],
        fallbackDisplayName: String?,
        maxParticipants: Int,
        includePhotos: Bool
    ) async -> ParticipantInfo {
        let resolvedParticipants = await resolveParticipants(
            for: emails,
            storedDisplayNamesByEmail: storedDisplayNamesByEmail,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail
        )
        let topParticipants = Array(resolvedParticipants.prefix(maxParticipants))
        let displayNames = Array(resolvedParticipants.compactMap { participant in
            participant.isRealDisplayName ? participant.displayName : nil
        }.prefix(maxParticipants))
        let topParticipantEmails = topParticipants.map(\.email)
        let avatarDisplayNames = topParticipants.map(\.displayName)
        let formattedName = PersonDisplayNameResolver.rowDisplayName(
            realNames: displayNames,
            totalParticipantCount: resolvedParticipants.count,
            fallback: fallbackDisplayName,
            participantEmails: emails
        )
        let avatarPhotos = includePhotos ? await loadPhotoSlots(for: topParticipantEmails) : []
        let photos = avatarPhotos.compactMap { $0 }

        return ParticipantInfo(
            emails: topParticipantEmails,
            displayNames: displayNames,
            photos: photos,
            formattedDisplayName: formattedName,
            totalUniqueParticipants: resolvedParticipants.count,
            avatarDisplayNames: avatarDisplayNames,
            avatarPhotos: avatarPhotos
        )
    }

    private func upgradeParticipantInfoWithPhotos(_ baseInfo: ParticipantInfo) async -> ParticipantInfo {
        guard !baseInfo.emails.isEmpty else { return baseInfo }
        let avatarPhotos = await loadPhotoSlots(for: baseInfo.emails)

        return ParticipantInfo(
            emails: baseInfo.emails,
            displayNames: baseInfo.displayNames,
            photos: avatarPhotos.compactMap { $0 },
            formattedDisplayName: baseInfo.formattedDisplayName,
            totalUniqueParticipants: baseInfo.totalUniqueParticipants,
            avatarDisplayNames: baseInfo.avatarDisplayNames,
            avatarPhotos: avatarPhotos
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

    private func resolveDisplayName(
        for email: String,
        match: ContactMatch?,
        storedDisplayName: String?,
        headerDisplayName: String?
    ) async -> (name: String, isReal: Bool) {
        let resolvedFromSnapshot = PersonDisplayNameResolver.participantDisplayName(
            email: email,
            contactDisplayName: match?.displayName,
            headerDisplayName: headerDisplayName,
            storedDisplayName: storedDisplayName
        )
        if resolvedFromSnapshot.isReal {
            return resolvedFromSnapshot
        }

        let cachedName: String?
        if let cachedDisplayNameProvider {
            cachedName = await cachedDisplayNameProvider(email)
        } else {
            cachedName = await personCache.getCachedDisplayName(for: email)
        }

        let resolvedFromCache = PersonDisplayNameResolver.participantDisplayName(
            email: email,
            contactDisplayName: nil,
            headerDisplayName: nil,
            storedDisplayName: cachedName
        )
        if resolvedFromCache.isReal {
            return resolvedFromCache
        }

        return resolvedFromSnapshot
    }

    private func loadPhotoSlots(for emails: [String]) async -> [ProfilePhoto?] {
        if let photoLoader {
            let loadedPhotos = await photoLoader(emails)
            return emails.indices.map { index in
                index < loadedPhotos.count ? loadedPhotos[index] : nil
            }
        }

        let photoResults = await photoResolver.resolvePhotos(for: emails)
        return emails.map { email in
            photoResults[EmailNormalizer.normalize(email)]
        }
    }

}
