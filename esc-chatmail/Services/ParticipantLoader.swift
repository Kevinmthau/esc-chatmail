import Foundation
import CoreData
import Contacts

protocol ParticipantRollupDependencyTracking: AnyObject {
    func fingerprint(for emails: [String]) -> ParticipantRollupDependencyFingerprint
    func invalidate(email: String)
    func invalidateAll()
}

struct ParticipantRollupDependencyFingerprint: Equatable, Sendable {
    let globalGeneration: UInt64
    let emailGenerations: [String: UInt64]
    let contactsAuthorizationStatusRawValue: Int
}

final class ParticipantRollupDependencyTracker: ParticipantRollupDependencyTracking, @unchecked Sendable {
    static let shared = ParticipantRollupDependencyTracker()

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var contactsDidChangeObserver: NSObjectProtocol?
    private var nextGeneration: UInt64 = 1
    private var globalGeneration: UInt64 = 0
    private var emailGenerations: [String: UInt64] = [:]

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        self.contactsDidChangeObserver = notificationCenter.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateAll()
        }
    }

    deinit {
        if let contactsDidChangeObserver {
            notificationCenter.removeObserver(contactsDidChangeObserver)
        }
    }

    func fingerprint(for emails: [String]) -> ParticipantRollupDependencyFingerprint {
        let normalizedEmails = normalizedUniqueEmails(from: emails)
        let contactsAuthorizationStatusRawValue = CNContactStore.authorizationStatus(for: .contacts).rawValue

        lock.lock()
        defer { lock.unlock() }

        var versions: [String: UInt64] = [:]
        versions.reserveCapacity(normalizedEmails.count)

        for email in normalizedEmails {
            versions[email] = emailGenerations[email] ?? 0
        }

        return ParticipantRollupDependencyFingerprint(
            globalGeneration: globalGeneration,
            emailGenerations: versions,
            contactsAuthorizationStatusRawValue: contactsAuthorizationStatusRawValue
        )
    }

    func invalidate(email: String) {
        let normalizedEmail = EmailNormalizer.normalize(email)
        guard !normalizedEmail.isEmpty else {
            invalidateAll()
            return
        }

        lock.lock()
        emailGenerations[normalizedEmail] = nextGeneration
        nextGeneration &+= 1
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        globalGeneration = nextGeneration
        nextGeneration &+= 1
        emailGenerations.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func normalizedUniqueEmails(from emails: [String]) -> [String] {
        var seenEmails = Set<String>()
        var normalizedEmails: [String] = []

        for email in emails {
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty,
                  seenEmails.insert(normalizedEmail).inserted else {
                continue
            }

            normalizedEmails.append(normalizedEmail)
        }

        return normalizedEmails.sorted()
    }
}

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

    private struct ParticipantRollupCacheKey: Hashable {
        let conversationObjectID: NSManagedObjectID
        let currentUserEmail: String
        let maxParticipants: Int
    }

    private struct ParticipantRollupCacheToken: Equatable {
        let participantHash: String
        let fallbackDisplayName: String?
        let headerDisplayNamesByEmail: [String: String]?
    }

    private struct CachedParticipantRollup {
        let token: ParticipantRollupCacheToken
        let sourceEmails: [String]
        let dependencyFingerprint: ParticipantRollupDependencyFingerprint
        let baseInfo: ParticipantInfo
        var photoInfo: ParticipantInfo?
        let cachedAt: Date
        var lastAccessedAt: Date

        func isExpired(now: Date, ttl: TimeInterval) -> Bool {
            now.timeIntervalSince(cachedAt) > ttl
        }

        func participantInfo(includePhotos: Bool) -> ParticipantInfo? {
            includePhotos ? photoInfo : baseInfo
        }
    }

    private let personCache: PersonCache
    private let photoResolver: ProfilePhotoResolver
    private let contactsResolver: any ContactsResolving
    private let currentUserAliasesProvider: ((NSManagedObjectContext?, String) async -> Set<String>)?
    private let prefetchDisplayNames: (@Sendable ([String]) async -> Void)?
    private let cachedDisplayNameProvider: (@Sendable (String) async -> String?)?
    private let photoLoader: (@Sendable ([String]) async -> [ProfilePhoto])?
    private let rollupDependencyTracker: any ParticipantRollupDependencyTracking
    private let participantRollupCacheTTL: TimeInterval
    private let maxParticipantRollupCacheEntries: Int
    private var participantRollupCache: [ParticipantRollupCacheKey: CachedParticipantRollup] = [:]

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
        self.rollupDependencyTracker = rollupDependencyTracker
        self.participantRollupCacheTTL = participantRollupCacheTTL
        self.maxParticipantRollupCacheEntries = maxParticipantRollupCacheEntries
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
        guard let token = makeCacheToken(
            participantHash: participantHash,
            sourceEmails: nil,
            fallbackDisplayName: fallbackDisplayName,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail
        ) else {
            return nil
        }

        let cacheKey = makeCacheKey(
            conversationObjectID: conversationObjectID,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants
        )

        return cachedParticipantInfo(
            for: cacheKey,
            token: token,
            includePhotos: includePhotos,
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
                storedDisplayNamesByEmail: Self.participantDisplayNamesByEmail(from: conversation),
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
           let upgradedCachedInfo = await upgradeCachedBaseParticipantInfoWithPhotos(
                conversationObjectID: conversationObjectID,
                participantHash: participantHash,
                currentUserEmail: currentUserEmail,
                maxParticipants: maxParticipants,
                fallbackDisplayName: fallbackDisplayName,
                headerDisplayNamesByEmail: [:]
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
           let upgradedCachedInfo = await upgradeCachedBaseParticipantInfoWithPhotos(
                conversationObjectID: conversationObjectID,
                participantHash: effectiveParticipantHash,
                currentUserEmail: currentUserEmail,
                maxParticipants: maxParticipants,
                fallbackDisplayName: snapshot.fallbackDisplayName,
                headerDisplayNamesByEmail: snapshot.headerDisplayNamesByEmail,
                evictOnTokenMismatch: true
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
        Self.extractNonMeParticipants(
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
        Self.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail,
            currentUserAliases: currentUserAliases
        )
    }

    nonisolated
    private static func extractNonMeParticipants(
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

    nonisolated
    private static func participantDisplayNamesByEmail(from conversation: Conversation) -> [String: String] {
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

            let emails = Self.extractNonMeParticipants(
                from: conversation,
                currentUserEmail: currentUserEmail,
                currentUserAliases: currentUserAliases
            )

            return ConversationParticipantSnapshot(
                emails: emails,
                storedDisplayNamesByEmail: Self.participantDisplayNamesByEmail(from: conversation),
                headerDisplayNamesByEmail: Self.headerDisplayNamesByEmail(
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

        cacheParticipantInfo(
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
        var aliases = Self.normalizedAliasSet(from: [currentUserEmail])

        if let currentUserAliasesProvider {
            aliases.formUnion(
                Self.normalizedAliasSet(
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

    nonisolated
    private static func normalizedAliasSet(from aliases: some Sequence<String>) -> Set<String> {
        Set(
            aliases
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
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

    nonisolated
    private static func headerDisplayNamesByEmail(
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

        let request = NSFetchRequest<NSDictionary>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["senderEmail", "senderName"]
        request.returnsDistinctResults = true
        request.predicate = NSPredicate(
            format: "conversation == %@ AND senderEmail != nil AND senderName != nil",
            conversation
        )
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

            if EmailNormalizer.isBetterDisplayName(
                displayName,
                than: displayNames[normalizedEmail],
                forEmail: normalizedEmail
            ) {
                displayNames[normalizedEmail] = displayName
            }
        }

        return displayNames
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

    private func cachedParticipantInfo(
        for cacheKey: ParticipantRollupCacheKey,
        token: ParticipantRollupCacheToken,
        includePhotos: Bool,
        evictOnTokenMismatch: Bool
    ) -> ParticipantInfo? {
        cachedParticipantRollup(
            for: cacheKey,
            token: token,
            evictOnTokenMismatch: evictOnTokenMismatch
        )?.participantInfo(includePhotos: includePhotos)
    }

    private func cachedParticipantRollup(
        for cacheKey: ParticipantRollupCacheKey,
        token: ParticipantRollupCacheToken,
        evictOnTokenMismatch: Bool
    ) -> CachedParticipantRollup? {
        guard var entry = participantRollupCache[cacheKey] else {
            return nil
        }

        let now = Date()
        guard !entry.isExpired(now: now, ttl: participantRollupCacheTTL) else {
            participantRollupCache.removeValue(forKey: cacheKey)
            return nil
        }

        guard cacheTokensMatch(entry.token, requestToken: token) else {
            if evictOnTokenMismatch {
                participantRollupCache.removeValue(forKey: cacheKey)
            }
            return nil
        }

        let currentFingerprint = rollupDependencyTracker.fingerprint(for: entry.sourceEmails)
        guard currentFingerprint == entry.dependencyFingerprint else {
            participantRollupCache.removeValue(forKey: cacheKey)
            return nil
        }

        entry.lastAccessedAt = now
        participantRollupCache[cacheKey] = entry
        return entry
    }

    private func upgradeCachedBaseParticipantInfoWithPhotos(
        conversationObjectID: NSManagedObjectID,
        participantHash: String?,
        currentUserEmail: String,
        maxParticipants: Int,
        fallbackDisplayName: String?,
        headerDisplayNamesByEmail: [String: String]? = nil,
        evictOnTokenMismatch: Bool = false
    ) async -> ParticipantInfo? {
        guard let token = makeCacheToken(
            participantHash: participantHash,
            sourceEmails: nil,
            fallbackDisplayName: fallbackDisplayName,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail
        ) else {
            return nil
        }

        let cacheKey = makeCacheKey(
            conversationObjectID: conversationObjectID,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants
        )

        guard let cachedRollup = cachedParticipantRollup(
            for: cacheKey,
            token: token,
            evictOnTokenMismatch: evictOnTokenMismatch
        ) else {
            return nil
        }

        if let photoInfo = cachedRollup.photoInfo {
            return photoInfo
        }

        let upgradedInfo = await upgradeParticipantInfoWithPhotos(cachedRollup.baseInfo)
        let now = Date()

        participantRollupCache[cacheKey] = CachedParticipantRollup(
            token: cachedRollup.token,
            sourceEmails: cachedRollup.sourceEmails,
            dependencyFingerprint: cachedRollup.dependencyFingerprint,
            baseInfo: cachedRollup.baseInfo,
            photoInfo: cacheablePhotoInfo(from: upgradedInfo),
            cachedAt: cachedRollup.cachedAt,
            lastAccessedAt: now
        )

        return upgradedInfo
    }

    private func cacheParticipantInfo(
        conversationObjectID: NSManagedObjectID,
        participantHash: String?,
        currentUserEmail: String,
        maxParticipants: Int,
        fallbackDisplayName: String?,
        sourceEmails: [String],
        headerDisplayNamesByEmail: [String: String] = [:],
        baseInfo: ParticipantInfo,
        fullInfo: ParticipantInfo?
    ) {
        guard let token = makeCacheToken(
            participantHash: participantHash,
            sourceEmails: sourceEmails,
            fallbackDisplayName: fallbackDisplayName,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail
        ) else {
            return
        }

        let cacheKey = makeCacheKey(
            conversationObjectID: conversationObjectID,
            currentUserEmail: currentUserEmail,
            maxParticipants: maxParticipants
        )
        let now = Date()

        participantRollupCache[cacheKey] = CachedParticipantRollup(
            token: token,
            sourceEmails: sourceEmails,
            dependencyFingerprint: rollupDependencyTracker.fingerprint(for: sourceEmails),
            baseInfo: baseInfo,
            photoInfo: cacheablePhotoInfo(from: fullInfo),
            cachedAt: now,
            lastAccessedAt: now
        )

        trimParticipantRollupCacheIfNeeded()
    }

    private func makeCacheKey(
        conversationObjectID: NSManagedObjectID,
        currentUserEmail: String,
        maxParticipants: Int
    ) -> ParticipantRollupCacheKey {
        ParticipantRollupCacheKey(
            conversationObjectID: conversationObjectID,
            currentUserEmail: EmailNormalizer.normalize(currentUserEmail),
            maxParticipants: maxParticipants
        )
    }

    private func makeCacheToken(
        participantHash: String?,
        sourceEmails: [String]?,
        fallbackDisplayName: String?,
        headerDisplayNamesByEmail: [String: String]? = nil
    ) -> ParticipantRollupCacheToken? {
        let trimmedParticipantHash = participantHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveParticipantHash: String?

        if let trimmedParticipantHash, !trimmedParticipantHash.isEmpty {
            effectiveParticipantHash = trimmedParticipantHash
        } else if let sourceEmails {
            let normalizedEmails = sourceEmails
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
            effectiveParticipantHash = calculateParticipantHash(from: normalizedEmails)
        } else {
            effectiveParticipantHash = nil
        }

        guard let effectiveParticipantHash, !effectiveParticipantHash.isEmpty else {
            return nil
        }

        return ParticipantRollupCacheToken(
            participantHash: effectiveParticipantHash,
            fallbackDisplayName: fallbackDisplayName,
            headerDisplayNamesByEmail: headerDisplayNamesByEmail.map(Self.cacheHeaderDisplayNamesByEmail)
        )
    }

    private func cacheTokensMatch(
        _ cachedToken: ParticipantRollupCacheToken,
        requestToken: ParticipantRollupCacheToken
    ) -> Bool {
        guard cachedToken.participantHash == requestToken.participantHash,
              cachedToken.fallbackDisplayName == requestToken.fallbackDisplayName else {
            return false
        }

        guard let requestHeaderDisplayNames = requestToken.headerDisplayNamesByEmail else {
            return true
        }

        return cachedToken.headerDisplayNamesByEmail == requestHeaderDisplayNames
    }

    private static func cacheHeaderDisplayNamesByEmail(_ displayNamesByEmail: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        for (email, displayName) in displayNamesByEmail {
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty,
                  let sanitizedDisplayName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                    displayName,
                    forEmail: normalizedEmail
                  ) else {
                continue
            }

            if EmailNormalizer.isBetterDisplayName(
                sanitizedDisplayName,
                than: result[normalizedEmail],
                forEmail: normalizedEmail
            ) {
                result[normalizedEmail] = sanitizedDisplayName
            }
        }

        return result
    }

    private func cacheablePhotoInfo(from participantInfo: ParticipantInfo?) -> ParticipantInfo? {
        guard let participantInfo else {
            return nil
        }

        // Keep raw avatar bytes in ProfilePhotoResolver's bounded cache, not this rollup dictionary.
        guard participantInfo.photos.allSatisfy({ $0.imageData == nil }) else {
            return nil
        }

        return participantInfo
    }

    private func trimParticipantRollupCacheIfNeeded() {
        guard participantRollupCache.count > maxParticipantRollupCacheEntries else {
            return
        }

        let entriesByAge = participantRollupCache.sorted { lhs, rhs in
            lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
        }
        let overflowCount = participantRollupCache.count - maxParticipantRollupCacheEntries

        for (cacheKey, _) in entriesByAge.prefix(overflowCount) {
            participantRollupCache.removeValue(forKey: cacheKey)
        }
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
