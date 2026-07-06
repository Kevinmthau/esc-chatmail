import Foundation
import CoreData

/// In-memory rollup cache for resolved `ParticipantLoader.ParticipantInfo`,
/// keyed by conversation + current user + participant count and validated by a
/// content token plus a dependency fingerprint (so contact/name changes evict
/// stale entries). Holds an LRU bound and a TTL, and supports upgrading a cached
/// photo-free base rollup with photos on demand.
///
/// Extracted from `ParticipantLoader` so the caching policy lives in one focused,
/// independently testable unit. The dependency tracker and the TTL / max-entries
/// limits are injected; the photo upgrade is supplied as a closure by the loader
/// (which still owns photo resolution). `@MainActor`, matching the loader, so the
/// mutable dictionary needs no additional locking.
@MainActor
final class ParticipantRollupCache {
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
        let baseInfo: ParticipantLoader.ParticipantInfo
        var photoInfo: ParticipantLoader.ParticipantInfo?
        let cachedAt: Date
        var lastAccessedAt: Date

        func isExpired(now: Date, ttl: TimeInterval) -> Bool {
            now.timeIntervalSince(cachedAt) > ttl
        }

        func participantInfo(includePhotos: Bool) -> ParticipantLoader.ParticipantInfo? {
            includePhotos ? photoInfo : baseInfo
        }
    }

    private let rollupDependencyTracker: any ParticipantRollupDependencyTracking
    private let participantRollupCacheTTL: TimeInterval
    private let maxParticipantRollupCacheEntries: Int
    private var participantRollupCache: [ParticipantRollupCacheKey: CachedParticipantRollup] = [:]

    init(
        rollupDependencyTracker: any ParticipantRollupDependencyTracking,
        participantRollupCacheTTL: TimeInterval,
        maxParticipantRollupCacheEntries: Int
    ) {
        self.rollupDependencyTracker = rollupDependencyTracker
        self.participantRollupCacheTTL = participantRollupCacheTTL
        self.maxParticipantRollupCacheEntries = maxParticipantRollupCacheEntries
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
    ) -> ParticipantLoader.ParticipantInfo? {
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

    func upgradeCachedBaseParticipantInfoWithPhotos(
        conversationObjectID: NSManagedObjectID,
        participantHash: String?,
        currentUserEmail: String,
        maxParticipants: Int,
        fallbackDisplayName: String?,
        headerDisplayNamesByEmail: [String: String]? = nil,
        evictOnTokenMismatch: Bool = false,
        upgrade: (ParticipantLoader.ParticipantInfo) async -> ParticipantLoader.ParticipantInfo
    ) async -> ParticipantLoader.ParticipantInfo? {
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

        let upgradedInfo = await upgrade(cachedRollup.baseInfo)
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

    func cacheParticipantInfo(
        conversationObjectID: NSManagedObjectID,
        participantHash: String?,
        currentUserEmail: String,
        maxParticipants: Int,
        fallbackDisplayName: String?,
        sourceEmails: [String],
        headerDisplayNamesByEmail: [String: String] = [:],
        baseInfo: ParticipantLoader.ParticipantInfo,
        fullInfo: ParticipantLoader.ParticipantInfo?
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

    private func cachedParticipantInfo(
        for cacheKey: ParticipantRollupCacheKey,
        token: ParticipantRollupCacheToken,
        includePhotos: Bool,
        evictOnTokenMismatch: Bool
    ) -> ParticipantLoader.ParticipantInfo? {
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

    private func cacheablePhotoInfo(from participantInfo: ParticipantLoader.ParticipantInfo?) -> ParticipantLoader.ParticipantInfo? {
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
}
