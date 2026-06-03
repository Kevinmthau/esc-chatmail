import XCTest
import CoreData
@testable import esc_chatmail

final class AliasManagerTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    func testGetAliasesMergesAccountAliasesWithSelfContactAliases() async throws {
        _ = AccountBuilder()
            .withEmail("KM.Thau@googlemail.com")
            .withAliases(["alias+tag@gmail.com"])
            .build(in: context)
        try context.save()

        let selfAliasProvider = StubSelfAliasProvider(aliases: ["kthau@me.com"])
        let manager = AliasManager(selfAliasProvider: selfAliasProvider)

        let aliases = await manager.getAliases(from: context)

        XCTAssertEqual(aliases, [
            "alias@gmail.com",
            "kmthau@gmail.com",
            "kthau@me.com"
        ])
        XCTAssertTrue(selfAliasProvider.searchedEmails.contains("KM.Thau@googlemail.com"))
    }

    func testGetAliasesPreservesAccountAliasesWhenSelfContactAliasesUnavailable() async throws {
        _ = AccountBuilder()
            .withEmail("me@example.com")
            .withAliases(["send-as@example.com"])
            .build(in: context)
        try context.save()

        let manager = AliasManager(selfAliasProvider: StubSelfAliasProvider(aliases: []))

        let aliases = await manager.getAliases(from: context)

        XCTAssertEqual(aliases, [
            "me@example.com",
            "send-as@example.com"
        ])
    }

    func testGetAliasesRecomputesSelfContactAliasesWhenContactDependenciesChange() async throws {
        let selfAliasProvider = StubSelfAliasProvider(aliases: [])
        let rollupDependencyTracker = StubRollupDependencyTracker()
        let manager = AliasManager(
            selfAliasProvider: selfAliasProvider,
            rollupDependencyTracker: rollupDependencyTracker
        )

        let cachedAliases = await manager.setAliases(["me@example.com"])

        XCTAssertEqual(cachedAliases, ["me@example.com"])
        XCTAssertEqual(selfAliasProvider.searchCount, 1)

        selfAliasProvider.setAliases(["me@icloud.com"])
        rollupDependencyTracker.simulateContactDependencyChange()

        let refreshedAliases = await manager.getAliases(from: context)

        XCTAssertEqual(refreshedAliases, [
            "me@example.com",
            "me@icloud.com"
        ])
        XCTAssertEqual(selfAliasProvider.searchCount, 2)
        XCTAssertEqual(selfAliasProvider.searchedEmails, ["me@example.com"])
    }

    func testGetCachedAliasesRecomputesSelfContactAliasesWhenContactDependenciesChange() async throws {
        let selfAliasProvider = StubSelfAliasProvider(aliases: [])
        let rollupDependencyTracker = StubRollupDependencyTracker()
        let manager = AliasManager(
            selfAliasProvider: selfAliasProvider,
            rollupDependencyTracker: rollupDependencyTracker
        )

        _ = await manager.setAliases(["me@example.com"])

        selfAliasProvider.setAliases(["me@icloud.com"])
        rollupDependencyTracker.simulateContactDependencyChange()

        let refreshedAliases = await manager.getCachedAliases()

        XCTAssertEqual(refreshedAliases, [
            "me@example.com",
            "me@icloud.com"
        ])
        XCTAssertEqual(selfAliasProvider.searchCount, 2)
    }
}

private final class StubSelfAliasProvider: SelfAliasProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var aliases: Set<String>
    private var _searchedEmails: [String] = []
    private var _searchCount = 0

    init(aliases: Set<String>) {
        self.aliases = aliases
    }

    func setAliases(_ aliases: Set<String>) {
        lock.lock()
        self.aliases = aliases
        lock.unlock()
    }

    var searchedEmails: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _searchedEmails
    }

    var searchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _searchCount
    }

    func aliases(knownEmails: [String]) async -> Set<String> {
        recordAliasesRequest(knownEmails: knownEmails)
    }

    private func recordAliasesRequest(knownEmails: [String]) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        _searchedEmails = knownEmails
        _searchCount += 1
        let aliases = aliases
        return aliases
    }
}

private final class StubRollupDependencyTracker: ParticipantRollupDependencyTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func fingerprint(for emails: [String]) -> ParticipantRollupDependencyFingerprint {
        lock.lock()
        defer { lock.unlock() }

        return ParticipantRollupDependencyFingerprint(
            globalGeneration: generation,
            emailGenerations: [:],
            contactsAuthorizationStatusRawValue: 0
        )
    }

    func invalidate(email: String) {
        simulateContactDependencyChange()
    }

    func invalidateAll() {
        simulateContactDependencyChange()
    }

    func simulateContactDependencyChange() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}
