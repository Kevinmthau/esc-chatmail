import CoreData
import XCTest
@testable import esc_chatmail

/// F19: `ProfilePhotoResolver.prefetchPhotos(for:)` must skip emails the
/// memory cache already resolves and must not start the Contacts batch
/// lookup once its task is cancelled. Recurring prefetch callers (chat-list
/// reloads, sync batches) previously re-enumerated the address book and
/// rewrote avatars for warm entries on every call.
final class ProfilePhotoResolverPrefetchGateTests: XCTestCase {
    private var testStack: TestCoreDataStack!

    override func tearDown() {
        testStack = nil
        super.tearDown()
    }

    // Revert-check: ProfilePhotoResolver.prefetchPhotos's memory-cache gate
    // (the unexpiredCachedPhoto filter ahead of resolveAvatarDataBatch) —
    // without it every warm email re-runs the Contacts batch enumeration.
    func testPrefetchPhotos_allEmailsMemoryCached_skipsContactsBatchLookup() async throws {
        let email = "warm@example.com"
        let contacts = RecordingContactsResolver(avatarsByNormalizedEmail: [:])
        let resolver = try makeResolver(contactsResolver: contacts, personEmails: [email])

        // Warm the memory cache: no contact match and no persisted avatar URL
        // caches a negative entry, which resolvePhoto answers without lookup.
        _ = await resolver.resolvePhoto(for: email)

        await resolver.prefetchPhotos(for: [email])

        let batchRequests = await contacts.batchRequests
        XCTAssertTrue(
            batchRequests.isEmpty,
            "A memory-cached email must not reach the Contacts batch lookup"
        )
    }

    // Revert-check: ProfilePhotoResolver.prefetchPhotos's memory-cache gate —
    // it must pass genuinely uncached emails through unchanged: the batch
    // receives exactly the uncached ones and their photos still land in the
    // memory cache.
    func testPrefetchPhotos_mixedCachedAndUncachedEmails_batchesOnlyUncached() async throws {
        let warmEmail = "warm@example.com"
        let coldEmail = "cold@example.com"
        let coldData = Data([0x0C])
        let contacts = RecordingContactsResolver(
            avatarsByNormalizedEmail: [EmailNormalizer.normalize(coldEmail): coldData]
        )
        let resolver = try makeResolver(
            contactsResolver: contacts,
            personEmails: [warmEmail, coldEmail]
        )

        _ = await resolver.resolvePhoto(for: warmEmail)
        await resolver.prefetchPhotos(for: [warmEmail, coldEmail])

        let batchRequests = await contacts.batchRequests
        XCTAssertEqual(batchRequests, [[coldEmail]])

        // The uncached email was fully processed: its photo now answers from
        // the memory cache without any further single Contacts lookup.
        let coldPhoto = await resolver.resolvePhoto(for: coldEmail)
        XCTAssertEqual(coldPhoto?.imageData, coldData)
        let singleRequests = await contacts.singleRequests
        XCTAssertEqual(singleRequests, [EmailNormalizer.normalize(warmEmail)])
    }

    // Revert-check: ProfilePhotoResolver.prefetchPhotos's Task.isCancelled
    // guard immediately before resolveAvatarDataBatch — without it a
    // superseded prefetch task still starts the Contacts enumeration.
    func testPrefetchPhotos_cancelledBeforeBatchLookup_neverStartsContactsEnumeration() async throws {
        let email = "cold@example.com"
        let contacts = RecordingContactsResolver(avatarsByNormalizedEmail: [:])
        let resolver = try makeResolver(contactsResolver: contacts, personEmails: [email])

        let task = Task {
            // Condition-bounded, not a fixed yield count: the unconditional
            // cancel() below guarantees this loop terminates, and it makes
            // prefetchPhotos run with cancellation already observed.
            while !Task.isCancelled {
                await Task.yield()
            }
            await resolver.prefetchPhotos(for: [email])
        }
        task.cancel()
        await task.value

        let batchRequests = await contacts.batchRequests
        XCTAssertTrue(
            batchRequests.isEmpty,
            "A cancelled prefetch must not start the Contacts batch lookup"
        )
    }

    // MARK: - Helpers

    private func makeResolver(
        contactsResolver: any ContactsResolving,
        personEmails: [String]
    ) throws -> ProfilePhotoResolver {
        let stack = TestCoreDataStack()
        testStack = stack
        for email in personEmails {
            _ = PersonBuilder.emailOnly(email, in: stack.viewContext)
        }
        try stack.saveViewContext()
        return ProfilePhotoResolver(
            contactsResolver: contactsResolver,
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            saveAvatar: { _, _ in nil },
            loadAvatar: { _ in nil },
            migrateAvatar: { _, _ in nil }
        )
    }
}

/// Hermetic ContactsResolving recorder: never touches CNContactStore (so the
/// suite passes regardless of the simulator's Contacts TCC state) and records
/// every single and batch avatar request so tests can assert the prefetch
/// gate short-circuits before the batch lookup.
private actor RecordingContactsResolver: ContactsResolving {
    private let avatarsByNormalizedEmail: [String: Data]
    private(set) var batchRequests: [[String]] = []
    private(set) var singleRequests: [String] = []

    init(avatarsByNormalizedEmail: [String: Data]) {
        self.avatarsByNormalizedEmail = avatarsByNormalizedEmail
    }

    func ensureAuthorization() async throws {}
    func lookup(email: String) async -> ContactMatch? { nil }
    func prewarm(emails: [String]) async {}

    func resolveAvatarData(for email: String) async -> Data? {
        singleRequests.append(email)
        return avatarsByNormalizedEmail[EmailNormalizer.normalize(email)]
    }

    func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data] {
        batchRequests.append(emails)
        var results: [String: Data] = [:]
        for email in emails {
            let normalized = EmailNormalizer.normalize(email)
            if let data = avatarsByNormalizedEmail[normalized] {
                results[normalized] = data
            }
        }
        return results
    }
}
