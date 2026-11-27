import XCTest
import CoreData
@testable import esc_chatmail

/// Fixtures, saves, and assertions go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never `stack.viewContext`,
/// which is private-queue. The test bodies use it directly, so `@MainActor` on
/// the class is what puts those accesses on-queue; see that helper for what the
/// private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class AliasManagerTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    /// An `invalidate()` that lands while a load is suspended in Core Data wins. A sign-in
    /// over another account's store resets the store between the load's read and its cache
    /// write (`AuthSession.performDurableLocalCleanup` invalidates after the reset), and
    /// the old row's addresses, cached then, would be the new account's own until the
    /// first sync's profile fetch. The load still answers its caller, who asked under the
    /// old account; the next load reads the store again.
    ///
    /// Revert-check: the `invalidationEpoch` comparison in `AliasManager.getAliases`
    /// (the suspended load's result is cached: `hasCachedAliases` is true after it
    /// returns, and the next load answers the old account's address).
    func testInvalidate_whileALoadIsSuspendedInCoreData_cachesNothing() async throws {
        let account = AccountBuilder().withEmail("old@example.com").build(in: context)
        try context.save()
        let manager = AliasManager(
            contactSelfAddresses: { _ in [] },
            rollupDependencyTracker: StubRollupDependencyTracker()
        )
        let gated = FetchGatingContext(
            gatedEntityName: "Account",
            coordinator: stack.persistentContainer.persistentStoreCoordinator
        )
        let load = Task.detached { await manager.getAliases(from: gated) }
        await gated.waitUntilFetchIsReached()

        await manager.invalidate()
        gated.releaseFetch()
        let loaded = await load.value

        XCTAssertEqual(loaded, ["old@example.com"], "The load still answers the caller that asked under the old account")
        let cached = await manager.hasCachedAliases
        XCTAssertFalse(cached, "Nothing the suspended load read is cached")

        account.email = "new@example.com"
        try context.save()
        let afterwards = await manager.getAliases(from: stack.newBackgroundContext())
        XCTAssertEqual(afterwards, ["new@example.com"], "The next load reads the store again")
    }

    /// The user's own addresses Contacts add come from the set the link store adopted,
    /// decided by `SelfContactCards`: a household card {me, spouse} does not make the
    /// spouse the user when the spouse has a card of their own.
    ///
    /// Revert-check: the `SelfContactCards.selfAddresses` call in
    /// `ContactLinkedAddressStore.adoptSelfAddresses` (every address of a card listing
    /// the account's address then counts, the spouse's included).
    func testGetAliases_householdCard_excludesTheSpouse_andKeepsTheUsersOwnCard() async throws {
        _ = AccountBuilder().withEmail("me@example.com").build(in: context)
        try context.save()
        let addressBook = AddressBookCards([
            ["me@example.com", "spouse@example.com"],
            ["spouse@example.com", "spouse@work.example"],
            ["me@example.com", "me@icloud.com"]
        ])
        let store = makeStore(addressBook)
        store.refreshIfNeeded(knownAddresses: ["me@example.com"])
        let manager = AliasManager(
            contactSelfAddresses: { store.selfAddressesSnapshot(forKnown: $0) },
            rollupDependencyTracker: StubRollupDependencyTracker()
        )

        let aliases = await manager.getAliases(from: context)

        XCTAssertEqual(aliases, ["me@example.com", "me@icloud.com"])
    }

    /// The alias set reads no Contacts: an edit to a card changes nothing until the
    /// cleanup pass adopts it, and an address book that cannot be read changes nothing
    /// either, so a hash never moves between two adoptions.
    ///
    /// Revert-check: the `cachedContactSelfAddresses ==` term of `AliasManager.getAliases`
    /// (the cache keeps the set from before the adoption).
    /// HONEST SCOPE: that the lookup reads no Contacts is structural (`AliasManager` has
    /// no Contacts reader); the read count only shows that nothing else read meanwhile.
    func testGetAliases_readsNoContacts_andKeepsItsSetUntilAdoption() async throws {
        _ = AccountBuilder().withEmail("me@example.com").build(in: context)
        try context.save()
        let addressBook = AddressBookCards([["me@example.com", "me@icloud.com"]])
        let store = makeStore(addressBook)
        store.refreshIfNeeded(knownAddresses: ["me@example.com"])
        let readsAfterAdoption = addressBook.readCount
        let manager = AliasManager(
            contactSelfAddresses: { store.selfAddressesSnapshot(forKnown: $0) },
            rollupDependencyTracker: StubRollupDependencyTracker()
        )

        addressBook.cards = [["me@example.com", "me@icloud.com", "me@old.example"]]
        let beforeAdoption = await manager.getAliases(from: context)
        XCTAssertEqual(beforeAdoption, ["me@example.com", "me@icloud.com"])
        XCTAssertEqual(addressBook.readCount, readsAfterAdoption, "Looking up aliases reads no Contacts")

        addressBook.cards = nil
        store.markContactsChanged()
        store.refreshIfNeeded(knownAddresses: ["me@example.com"])
        let afterAFailedRead = await manager.getAliases(from: context)
        XCTAssertEqual(afterAFailedRead, ["me@example.com", "me@icloud.com"], "An unreadable address book is never an empty set")

        addressBook.cards = [["me@example.com", "me@icloud.com", "me@old.example"]]
        store.markContactsChanged()
        store.refreshIfNeeded(knownAddresses: ["me@example.com"])
        let afterAdoption = await manager.getAliases(from: context)
        XCTAssertEqual(afterAdoption, ["me@example.com", "me@icloud.com", "me@old.example"])
    }

    /// A set decided for another account answers nothing: it never makes one account's
    /// card addresses the next account's own.
    ///
    /// Revert-check: the `isDisjoint(with: known)` guard in
    /// `ContactLinkedAddressStore.selfAddressesSnapshot`.
    func testGetAliases_setDecidedForAnotherAccount_addsNothing() async throws {
        _ = AccountBuilder().withEmail("next@example.com").build(in: context)
        try context.save()
        let store = makeStore(AddressBookCards([["me@example.com", "me@icloud.com"]]))
        store.refreshIfNeeded(knownAddresses: ["me@example.com"])
        let manager = AliasManager(
            contactSelfAddresses: { store.selfAddressesSnapshot(forKnown: $0) },
            rollupDependencyTracker: StubRollupDependencyTracker()
        )

        let aliases = await manager.getAliases(from: context)

        XCTAssertEqual(aliases, ["next@example.com"])
    }

    func testGetAliasesPreservesAccountAliasesWhenNoSelfAddressesWereAdopted() async throws {
        _ = AccountBuilder()
            .withEmail("KM.Thau@googlemail.com")
            .withAliases(["alias+tag@gmail.com"])
            .build(in: context)
        try context.save()

        let manager = AliasManager(contactSelfAddresses: { _ in [] })

        let aliases = await manager.getAliases(from: context)

        XCTAssertEqual(aliases, ["alias@gmail.com", "kmthau@gmail.com"])
    }

    /// Revert-check: the `cachedContactSelfAddresses ==` term of
    /// `AliasManager.getCachedAliases`.
    func testGetCachedAliasesRecomputesWhenTheAdoptedSetChanges() async throws {
        let selfAddresses = SelfAddressesBox()
        let rollupDependencyTracker = StubRollupDependencyTracker()
        let manager = AliasManager(
            contactSelfAddresses: { _ in selfAddresses.value },
            rollupDependencyTracker: rollupDependencyTracker
        )

        _ = await manager.setAliases(["me@example.com"])

        selfAddresses.value = ["me@icloud.com"]

        let refreshedAliases = await manager.getCachedAliases()

        XCTAssertEqual(refreshedAliases, ["me@example.com", "me@icloud.com"])
    }

    private func makeStore(_ addressBook: AddressBookCards) -> ContactLinkedAddressStore {
        ContactLinkedAddressStore(
            defaults: nil,
            notificationCenter: NotificationCenter(),
            contactsAuthorizationStatus: { .authorized },
            loadContactAddressLists: { addressBook.read() },
            loadMeCardAddresses: { [] }
        )
    }
}

/// An address book a test edits; counts its reads.
private final class AddressBookCards: @unchecked Sendable {
    /// `@unchecked Sendable`: `lock` guards `_cards` and `_readCount`.
    private let lock = NSLock()
    private var _cards: [[String]]?
    private var _readCount = 0

    init(_ cards: [[String]]?) { _cards = cards }

    var cards: [[String]]? {
        get { lock.withLock { _cards } }
        set { lock.withLock { _cards = newValue } }
    }

    var readCount: Int { lock.withLock { _readCount } }

    func read() -> [[String]]? {
        lock.withLock {
            _readCount += 1
            return _cards
        }
    }
}

/// `@unchecked Sendable`: `lock` guards `_value`.
private final class SelfAddressesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Set<String> = []

    var value: Set<String> {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
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
