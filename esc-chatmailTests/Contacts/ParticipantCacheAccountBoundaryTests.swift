import CoreData
import Contacts
import XCTest
@testable import esc_chatmail

final class ParticipantCacheAccountBoundaryTests: XCTestCase {
    func testContactsResolverDirectLookupCannotPersistOrReturnAcrossAccountGeneration() async throws {
        let email = "direct-contact@example.com"
        let oldData = Data([0x21])
        let newData = Data([0x22])
        let matches = DirectContactMatchScript(
            email: email,
            oldData: oldData,
            newData: newData
        )
        let avatarSaves = GatedDirectContactAvatarSaver()
        let (testStack, coreDataStack) = try makePersonStore(email: email)
        _ = testStack
        let resolver = ContactsResolver(
            authorizationStatusProvider: { .authorized },
            coreDataStack: coreDataStack,
            contactLookup: { email in
                matches.lookup(email: email)
            },
            saveAvatar: { email, data in
                await avatarSaves.save(email: email, data: data)
            }
        )
        let closeCompletion = AccountCloseCompletionRecorder()

        let oldLookup = Task {
            await resolver.lookup(email: email)
        }
        await avatarSaves.waitUntilFirstSaveStarts()

        let closeTask = Task {
            await resolver.closeAccountWorkAndClear()
            closeCompletion.markFinished()
        }
        let didClose = await waitUntilClosed(resolver)
        XCTAssertTrue(didClose)

        // Reopen while the first generation is still draining to prove the
        // new lookup neither joins nor receives the old lookup's cache/write.
        await resolver.reopenAccountWork()
        let newMatch = await resolver.lookup(email: email)
        XCTAssertEqual(newMatch?.displayName, "New Account Contact")
        XCTAssertEqual(newMatch?.imageData, newData)
        XCTAssertFalse(
            closeCompletion.isFinished,
            "Close must drain the old direct writer before AuthSession can reset Core Data"
        )

        await avatarSaves.releaseFirstSave()
        await closeTask.value
        let oldMatch = await oldLookup.value
        XCTAssertNil(oldMatch)

        let persisted = try await persistedPerson(in: coreDataStack, email: email)
        XCTAssertEqual(persisted.displayName, "New Account Contact")
        XCTAssertEqual(persisted.avatarURL, "file:///direct-contact/22")

        let cachedMatch = await resolver.lookup(email: email)
        let lookupCallCount = matches.callCount
        XCTAssertEqual(cachedMatch?.displayName, "New Account Contact")
        XCTAssertEqual(
            lookupCallCount,
            2,
            "The old lookup must not replace the reopened contact cache"
        )
    }

    func testPersonCacheStaleFetchCannotReturnOrOverwriteReopenedGeneration() async {
        let fetches = GatedPersonDisplayNameFetches()
        let cache = PersonCache(
            startsPeriodicCleanup: false,
            fetchDisplayName: { email in
                await fetches.fetch(email: email)
            }
        )
        let email = "person@example.com"

        let oldRequest = Task {
            await cache.getDisplayName(for: email)
        }
        await fetches.waitUntilFirstFetchStarts()

        let closeTask = Task {
            await cache.closeAccountWorkAndClear()
        }
        let didClose = await waitUntilClosed(cache)
        XCTAssertTrue(didClose)

        await cache.reopenAccountWork()
        let newName = await cache.getDisplayName(for: email)
        XCTAssertEqual(newName, "New Account Name")

        await fetches.releaseFirstFetch()
        await closeTask.value
        let oldName = await oldRequest.value

        XCTAssertEqual(oldName, PersonDisplayNameResolver.fallbackConversationName())
        let cachedName = await cache.getCachedDisplayName(for: email)
        let fetchCallCount = await fetches.callCount
        XCTAssertEqual(cachedName, "New Account Name")
        XCTAssertEqual(fetchCallCount, 2)
    }

    func testProfilePhotoResolverReopenedRequestDoesNotJoinOrAcceptOldRequest() async throws {
        let email = "avatar@example.com"
        let oldData = Data([0x01])
        let newData = Data([0x02])
        let contacts = GatedSinglePhotoContactsResolver(
            oldData: oldData,
            newData: newData
        )
        let saves = AvatarSaveRecorder()
        let (testStack, coreDataStack) = try makePersonStore(email: email)
        _ = testStack
        let resolver = ProfilePhotoResolver(
            contactsResolver: contacts,
            coreDataStack: coreDataStack,
            saveAvatar: { email, data in
                await saves.save(email: email, data: data)
            },
            loadAvatar: { _ in nil },
            migrateAvatar: { _, _ in nil }
        )

        let oldRequest = Task {
            await resolver.resolvePhoto(for: email)
        }
        await contacts.waitUntilFirstRequestStarts()

        let closeTask = Task {
            await resolver.closeAccountWorkAndClear()
        }
        let didClose = await waitUntilClosed(resolver)
        XCTAssertTrue(didClose)

        // Exercise the generation key directly: reopening while close is still
        // draining must start distinct work instead of joining the old email task.
        await resolver.reopenAccountWork()
        let newPhoto = await resolver.resolvePhoto(for: email)
        let requestCountAfterReopen = await contacts.singleRequestCount
        XCTAssertEqual(newPhoto?.imageData, newData)
        XCTAssertEqual(requestCountAfterReopen, 2)

        await contacts.releaseFirstRequest()
        await closeTask.value
        let oldPhoto = await oldRequest.value

        XCTAssertNil(oldPhoto, "An old-account result must not return after generation invalidation")
        let persistedURL = try await persistedAvatarURL(in: coreDataStack, email: email)
        let savedPayloads = await saves.savedPayloads
        XCTAssertEqual(persistedURL, "file:///test-avatar/02")
        XCTAssertEqual(savedPayloads, [newData])

        let cachedPhoto = await resolver.resolvePhoto(for: email)
        let finalRequestCount = await contacts.singleRequestCount
        XCTAssertEqual(cachedPhoto?.imageData, newData)
        XCTAssertEqual(
            finalRequestCount,
            2,
            "The stale result must not replace the reopened generation's memory entry"
        )
    }

    func testProfilePhotoResolverStaleBatchPrefetchCannotPersistOrReplaceNewMemory() async throws {
        let email = "prefetch@example.com"
        let oldData = Data([0x0A])
        let newData = Data([0x0B])
        let contacts = GatedBatchPhotoContactsResolver(
            email: email,
            oldData: oldData,
            newData: newData
        )
        let saves = AvatarSaveRecorder()
        let (testStack, coreDataStack) = try makePersonStore(email: email)
        _ = testStack
        let resolver = ProfilePhotoResolver(
            contactsResolver: contacts,
            coreDataStack: coreDataStack,
            saveAvatar: { email, data in
                await saves.save(email: email, data: data)
            },
            loadAvatar: { _ in nil },
            migrateAvatar: { _, _ in nil }
        )

        let oldPrefetch = Task {
            await resolver.prefetchPhotos(for: [email])
        }
        await contacts.waitUntilBatchStarts()

        let closeTask = Task {
            await resolver.closeAccountWorkAndClear()
        }
        let didClose = await waitUntilClosed(resolver)
        XCTAssertTrue(didClose)
        await resolver.reopenAccountWork()

        let newPhoto = await resolver.resolvePhoto(for: email)
        XCTAssertEqual(newPhoto?.imageData, newData)

        await contacts.releaseBatch()
        await closeTask.value
        await oldPrefetch.value

        let persistedURL = try await persistedAvatarURL(in: coreDataStack, email: email)
        let savedPayloads = await saves.savedPayloads
        let finalPhoto = await resolver.resolvePhoto(for: email)
        XCTAssertEqual(persistedURL, "file:///test-avatar/0b")
        XCTAssertEqual(savedPayloads, [newData])
        XCTAssertEqual(
            finalPhoto?.imageData,
            newData,
            "A stale batch result must not replace reopened memory"
        )
    }

    private func waitUntilClosed(_ cache: PersonCache) async -> Bool {
        for _ in 0..<1_000 {
            if await cache.captureAccountGeneration() == nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitUntilClosed(_ resolver: ProfilePhotoResolver) async -> Bool {
        for _ in 0..<1_000 {
            if await resolver.captureAccountGeneration() == nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitUntilClosed(_ resolver: ContactsResolver) async -> Bool {
        for _ in 0..<1_000 {
            if await resolver.captureAccountGeneration() == nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makePersonStore(email: String) throws -> (TestCoreDataStack, CoreDataStack) {
        let testStack = TestCoreDataStack()
        _ = PersonBuilder.emailOnly(email, in: testStack.viewContext)
        try testStack.saveViewContext()
        return (
            testStack,
            CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        )
    }

    private func persistedAvatarURL(
        in coreDataStack: CoreDataStack,
        email: String
    ) async throws -> String? {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            request.fetchLimit = 1
            return try context.fetch(request).first?.avatarURL
        }
    }

    private func persistedPerson(
        in coreDataStack: CoreDataStack,
        email: String
    ) async throws -> (displayName: String?, avatarURL: String?) {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            request.fetchLimit = 1
            let person = try context.fetch(request).first
            return (person?.displayName, person?.avatarURL)
        }
    }
}

private final class AccountCloseCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func markFinished() {
        lock.withLock { finished = true }
    }
}

private final class DirectContactMatchScript: @unchecked Sendable {
    private let lock = NSLock()
    private let email: String
    private let oldData: Data
    private let newData: Data
    private var _callCount = 0

    init(email: String, oldData: Data, newData: Data) {
        self.email = EmailNormalizer.normalize(email)
        self.oldData = oldData
        self.newData = newData
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func lookup(email: String) -> ContactMatch {
        lock.withLock {
            _callCount += 1
            if _callCount == 1 {
                return ContactMatch(
                    displayName: "Old Account Contact",
                    email: self.email,
                    imageData: oldData
                )
            }
            return ContactMatch(
                displayName: "New Account Contact",
                email: self.email,
                imageData: newData
            )
        }
    }
}

private actor GatedDirectContactAvatarSaver {
    private var firstSaveStarted = false
    private var firstSaveReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCount = 0

    func save(email: String, data: Data) async -> String? {
        callCount += 1
        guard callCount == 1 else {
            return avatarURL(for: data)
        }

        firstSaveStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !firstSaveReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return avatarURL(for: data)
    }

    func waitUntilFirstSaveStarts() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        firstSaveReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func avatarURL(for data: Data) -> String {
        let suffix = data.map { String(format: "%02x", $0) }.joined()
        return "file:///direct-contact/\(suffix)"
    }
}

private actor GatedPersonDisplayNameFetches {
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    func fetch(email: String) async -> String? {
        callCount += 1
        guard callCount == 1 else { return "New Account Name" }

        firstStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !firstReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return "Old Account Name"
    }

    func waitUntilFirstFetchStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstFetch() {
        firstReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AvatarSaveRecorder {
    private(set) var savedPayloads: [Data] = []

    func save(email: String, data: Data) -> String {
        savedPayloads.append(data)
        let suffix = data.map { String(format: "%02x", $0) }.joined()
        return "file:///test-avatar/\(suffix)"
    }
}

private actor GatedSinglePhotoContactsResolver: ContactsResolving {
    private let oldData: Data
    private let newData: Data
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var singleRequestCount = 0

    init(oldData: Data, newData: Data) {
        self.oldData = oldData
        self.newData = newData
    }

    func ensureAuthorization() async throws {}
    func lookup(email: String) async -> ContactMatch? { nil }
    func prewarm(emails: [String]) async {}

    func resolveAvatarData(for email: String) async -> Data? {
        singleRequestCount += 1
        guard singleRequestCount == 1 else { return newData }

        firstStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !firstReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return oldData
    }

    func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data] { [:] }

    func waitUntilFirstRequestStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        firstReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor GatedBatchPhotoContactsResolver: ContactsResolving {
    private let email: String
    private let oldData: Data
    private let newData: Data
    private var batchStarted = false
    private var batchReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(email: String, oldData: Data, newData: Data) {
        self.email = EmailNormalizer.normalize(email)
        self.oldData = oldData
        self.newData = newData
    }

    func ensureAuthorization() async throws {}
    func lookup(email: String) async -> ContactMatch? { nil }
    func prewarm(emails: [String]) async {}
    func resolveAvatarData(for email: String) async -> Data? { newData }

    func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data] {
        batchStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !batchReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return [email: oldData]
    }

    func waitUntilBatchStarts() async {
        guard !batchStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBatch() {
        batchReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
