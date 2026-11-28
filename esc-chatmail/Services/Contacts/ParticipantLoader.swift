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
    /// Makes the context a saved conversation's snapshot is read on, from the context
    /// the caller passed (`snapshotReadContext`). By default a private-queue context on
    /// the passed context's coordinator (`makePrivateSnapshotContext`).
    private let makeSnapshotContext: (NSManagedObjectContext) -> NSManagedObjectContext?
    /// The snapshot read under way for each conversation, so a row and a chat header
    /// asking at once read it once (`fetchConversationParticipantSnapshot`).
    private var snapshotsInFlight: [SnapshotKey: Task<ConversationParticipantSnapshot, Never>] = [:]

    private struct SnapshotKey: Hashable {
        let conversationObjectID: NSManagedObjectID
        let currentUserEmail: String
        let fallbackDisplayName: String?
    }

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
        maxParticipantRollupCacheEntries: Int = 600,
        makeSnapshotContext: @escaping (NSManagedObjectContext) -> NSManagedObjectContext? = ParticipantLoader.makePrivateSnapshotContext(on:)
    ) {
        self.makeSnapshotContext = makeSnapshotContext
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

    /// Resolves one conversation's participant records from the snapshot the chat header
    /// resolves with (`loadParticipants`): the alias-aware non-me participant emails, the newest
    /// explicit From header names and the stored Person names. The Participants sheet uses this.
    /// The bare `resolveParticipants(for:)` sees only Contacts and the Person cache, and the
    /// resolver rejects a cached name that restates the address ("Jacob Laycock" for
    /// jacob.laycock@…), so a sender the header named showed as "Unknown Contact" there. The
    /// sheet's own email list also excluded only the primary address, so it listed the user's
    /// send-as aliases, which the header leaves out.
    func resolveParticipants(
        inConversation conversationObjectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        currentUserEmail: String
    ) async -> [ResolvedParticipant] {
        let currentUserAliases = await loadCurrentUserAliases(
            currentUserEmail: currentUserEmail,
            context: context
        )
        let snapshot = await fetchConversationParticipantSnapshot(
            conversationObjectID: conversationObjectID,
            in: context,
            currentUserEmail: currentUserEmail,
            currentUserAliases: currentUserAliases,
            fallbackDisplayName: nil
        )

        return await resolver.resolveParticipants(
            for: snapshot.emails,
            storedDisplayNamesByEmail: snapshot.storedDisplayNamesByEmail,
            headerDisplayNamesByEmail: snapshot.headerDisplayNamesByEmail
        )
    }

    /// Resolves the people who wrote one conversation's received messages, for the sheet a
    /// mailing list's header opens (`ParticipantsListPolicy`). A list's participant rows are
    /// the people on the first message filed there, not who is in the list, so
    /// `resolveParticipants(inConversation:context:currentUserEmail:)` would name whoever
    /// happened to post first and nobody since.
    ///
    /// Named as that resolve names its rows: Contacts, then the newest explicit From header
    /// name. There is no stored Person name to offer, because these addresses have no
    /// participant row; each is the sender of a message, so its From header is the source.
    ///
    /// A list can have hundreds of senders, and each is asked of Contacts in turn. So they
    /// are resolved `batchSize` at a time, and `onProgress` is given the senders resolved so
    /// far after each batch but the last (`ParticipantInfoResolver`'s batched resolve): the
    /// sheet draws its first rows without waiting for its last. A list of no more than one
    /// batch, which is nearly every list, makes no such call. Once the calling task is
    /// cancelled the rest is not resolved, and the result is then short: the caller checks
    /// before it uses it.
    func resolveSenders(
        inConversation conversationObjectID: NSManagedObjectID,
        context: NSManagedObjectContext,
        currentUserEmail: String,
        batchSize: Int = ParticipantLoader.senderResolutionBatchSize,
        onProgress: (([ResolvedParticipant]) -> Void)? = nil
    ) async -> [ResolvedParticipant] {
        let currentUserAliases = await loadCurrentUserAliases(
            currentUserEmail: currentUserEmail,
            context: context
        )
        // Read off the main thread like the snapshot (`snapshotReadContext`): a list's
        // senders are every message's, through a DISTINCT fetch over all of them.
        let readContext = await snapshotReadContext(for: conversationObjectID, passed: context)
        let senders: (emails: [String], headerDisplayNamesByEmail: [String: String]) = await readContext.perform {
            guard let conversation = try? readContext.existingObject(with: conversationObjectID) as? Conversation,
                  !conversation.isDeleted else {
                return ([], [:])
            }

            let emails = ConversationParticipantExtractor.nonMeSenderEmails(
                in: readContext,
                conversation: conversation,
                currentUserEmail: currentUserEmail,
                currentUserAliases: currentUserAliases
            )
            return (
                emails,
                ConversationParticipantExtractor.headerDisplayNamesByEmail(
                    in: readContext,
                    conversation: conversation,
                    participantEmails: emails
                )
            )
        }

        return await resolver.resolveParticipants(
            for: senders.emails,
            storedDisplayNamesByEmail: [:],
            headerDisplayNamesByEmail: senders.headerDisplayNamesByEmail,
            inBatchesOf: batchSize,
            onProgress: { onProgress?($0) }
        )
    }

    /// How many of a mailing list's senders `resolveSenders` resolves before it hands over
    /// what it has. Small enough that the first rows come after a few Contacts queries, and
    /// more than the senders of nearly every list, so those are still resolved in one go.
    nonisolated static let senderResolutionBatchSize = 25

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

    /// The context the private-queue snapshot read is made on by default: a context of
    /// its own on the passed context's coordinator, with the app's merge policy (a context
    /// built by hand must set it; this one is never saved). Nil where the passed context
    /// has no coordinator (a child context), which then reads on itself.
    nonisolated static func makePrivateSnapshotContext(on context: NSManagedObjectContext) -> NSManagedObjectContext? {
        guard let coordinator = context.persistentStoreCoordinator else { return nil }
        let snapshotContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        snapshotContext.persistentStoreCoordinator = coordinator
        snapshotContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return snapshotContext
    }

    /// Where a conversation's snapshot is read. A saved conversation is read on a
    /// private-queue context (`makeSnapshotContext`), off the main thread: the snapshot
    /// walks the participants and makes a DISTINCT fetch of the From names over every
    /// message of the conversation, with no limit, and the list and the chat header pass
    /// the view context, so until 2026-11-28 that ran on the main thread for every row
    /// that missed the rollup cache and every chat opened (architecture review 2026-11,
    /// conversation-list-ui#1; scalability `row-header-distinct-sender-scan`).
    ///
    /// The passed context reads it where the store cannot answer: a temporary ID, and a
    /// conversation the passed context holds unsaved changes to. An optimistic send's
    /// conversation is the second kind with a permanent ID: the send obtains one before the
    /// list or the chat first sees it (`GmailSendService.createOptimisticMessage`), and a
    /// private context would find nothing, or the saved participants without the new ones.
    private func snapshotReadContext(
        for conversationObjectID: NSManagedObjectID,
        passed context: NSManagedObjectContext
    ) async -> NSManagedObjectContext {
        guard !conversationObjectID.isTemporaryID,
              let snapshotContext = makeSnapshotContext(context) else {
            return context
        }
        let hasUnsavedChanges = await context.perform {
            context.registeredObject(for: conversationObjectID)?.hasChanges == true
        }
        return hasUnsavedChanges ? context : snapshotContext
    }

    /// The snapshot of one conversation, read once for concurrent callers: a row and the
    /// chat header asking for the same conversation share the read in flight.
    private func fetchConversationParticipantSnapshot(
        conversationObjectID: NSManagedObjectID,
        in context: NSManagedObjectContext,
        currentUserEmail: String,
        currentUserAliases: Set<String>,
        fallbackDisplayName: String?
    ) async -> ConversationParticipantSnapshot {
        let key = SnapshotKey(
            conversationObjectID: conversationObjectID,
            currentUserEmail: EmailNormalizer.normalize(currentUserEmail),
            fallbackDisplayName: fallbackDisplayName
        )
        if let inFlight = snapshotsInFlight[key] {
            return await inFlight.value
        }
        let read = Task { @MainActor [self] in
            let readContext = await snapshotReadContext(for: conversationObjectID, passed: context)
            return await Self.readSnapshot(
                conversationObjectID: conversationObjectID,
                in: readContext,
                currentUserEmail: currentUserEmail,
                currentUserAliases: currentUserAliases,
                fallbackDisplayName: fallbackDisplayName
            )
        }
        snapshotsInFlight[key] = read
        let snapshot = await read.value
        snapshotsInFlight[key] = nil
        return snapshot
    }

    private nonisolated static func readSnapshot(
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

        // Photo resolution no longer suspends behind the Contacts permission
        // (lookups fail fast at .notDetermined), so awaiting the photo upgrade
        // here costs only thumbnail I/O and preserves the contract that
        // includePhotos callers receive photo-complete info.
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
