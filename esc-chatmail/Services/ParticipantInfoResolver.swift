import Foundation

/// Resolves participant emails into display-ready records and a fully assembled
/// `ParticipantLoader.ParticipantInfo` — deduplicating by address-book contact,
/// choosing the best display name per email, and loading avatar photo slots — and
/// produces the stable sender grouping keys used for chat-bubble run collapsing.
///
/// Extracted from `ParticipantLoader` so the contact/name/photo resolution lives
/// in one focused, independently testable unit, separate from the loader's
/// orchestration and caching. Owns the contacts/person/photo collaborators plus
/// the optional name-prefetch / cached-name / photo-loader overrides; `@MainActor`
/// to match the loader.
@MainActor
final class ParticipantInfoResolver {
    private let personCache: PersonCache
    private let photoResolver: ProfilePhotoResolver
    private let contactsResolver: any ContactsResolving
    private let prefetchDisplayNames: (@Sendable ([String]) async -> Void)?
    private let cachedDisplayNameProvider: (@Sendable (String) async -> String?)?
    private let photoLoader: (@Sendable ([String]) async -> [ProfilePhoto])?

    init(
        personCache: PersonCache,
        photoResolver: ProfilePhotoResolver,
        contactsResolver: any ContactsResolving,
        prefetchDisplayNames: (@Sendable ([String]) async -> Void)?,
        cachedDisplayNameProvider: (@Sendable (String) async -> String?)?,
        photoLoader: (@Sendable ([String]) async -> [ProfilePhoto])?
    ) {
        self.personCache = personCache
        self.photoResolver = photoResolver
        self.contactsResolver = contactsResolver
        self.prefetchDisplayNames = prefetchDisplayNames
        self.cachedDisplayNameProvider = cachedDisplayNameProvider
        self.photoLoader = photoLoader
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
    func resolveParticipants(for emails: [String]) async -> [ParticipantLoader.ResolvedParticipant] {
        await resolveParticipants(
            for: emails,
            storedDisplayNamesByEmail: [:],
            headerDisplayNamesByEmail: [:]
        )
    }

    func resolveParticipants(
        for emails: [String],
        storedDisplayNamesByEmail: [String: String],
        headerDisplayNamesByEmail: [String: String]
    ) async -> [ParticipantLoader.ResolvedParticipant] {
        guard !emails.isEmpty else { return [] }

        await prefetchNamesIfNeeded(for: emails)

        var resolvedParticipants: [ParticipantLoader.ResolvedParticipant] = []
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
                ParticipantLoader.ResolvedParticipant(
                    email: email,
                    displayName: resolvedDisplayName.name,
                    isRealDisplayName: resolvedDisplayName.isReal,
                    contactIdentifier: match?.contactIdentifier
                )
            )
        }

        return resolvedParticipants
    }

    func buildParticipantInfo(
        emails: [String],
        storedDisplayNamesByEmail: [String: String],
        headerDisplayNamesByEmail: [String: String],
        fallbackDisplayName: String?,
        maxParticipants: Int,
        includePhotos: Bool
    ) async -> ParticipantLoader.ParticipantInfo {
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

        return ParticipantLoader.ParticipantInfo(
            emails: topParticipantEmails,
            displayNames: displayNames,
            photos: photos,
            formattedDisplayName: formattedName,
            totalUniqueParticipants: resolvedParticipants.count,
            avatarDisplayNames: avatarDisplayNames,
            avatarPhotos: avatarPhotos
        )
    }

    func upgradeParticipantInfoWithPhotos(_ baseInfo: ParticipantLoader.ParticipantInfo) async -> ParticipantLoader.ParticipantInfo {
        guard !baseInfo.emails.isEmpty else { return baseInfo }
        let avatarPhotos = await loadPhotoSlots(for: baseInfo.emails)

        return ParticipantLoader.ParticipantInfo(
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
