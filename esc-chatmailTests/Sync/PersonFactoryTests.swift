import XCTest
import CoreData
@testable import esc_chatmail

/// Tests for PersonFactory's find-or-create semantics and the context-scoped
/// cache that the batch prefetch primes.
final class PersonFactoryTests: XCTestCase {

    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        stack = nil
        context = nil
        super.tearDown()
    }

    private func personCount(email: String) throws -> Int {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", email)
        return try context.fetch(request).count
    }

    // MARK: - Prefetch

    func testPrefetch_toleratesDuplicateEmailRows() throws {
        // Duplicate-email Person rows are legal (no uniqueness constraint on
        // Person.email); the previous Dictionary(uniqueKeysWithValues:) trapped.
        try context.performAndWait {
            PersonBuilder().withEmail("dupe@example.com").withDisplayName("First").build(in: context)
            PersonBuilder().withEmail("dupe@example.com").withDisplayName("Second").build(in: context)
            try context.save()

            let result = PersonFactory.prefetch(emails: ["dupe@example.com"], in: context)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result["dupe@example.com"]?.email, "dupe@example.com")
        }
    }

    func testPrefetch_primesCacheSoFindOrCreateReturnsSameInstance() throws {
        try context.performAndWait {
            let existing = PersonBuilder().withEmail("cached@example.com").withDisplayName("Cached").build(in: context)
            try context.save()

            let prefetched = PersonFactory.prefetch(emails: ["cached@example.com"], in: context)
            XCTAssertTrue(prefetched["cached@example.com"] === existing)

            let found = try PersonFactory.findOrCreate(
                email: "cached@example.com",
                displayName: nil,
                in: context
            )
            XCTAssertTrue(found === existing)
        }
    }

    func testPrefetch_normalizesEmailsBeforeFetching() throws {
        try context.performAndWait {
            let existing = PersonBuilder().withEmail("johndoe@gmail.com").withDisplayName("John").build(in: context)
            try context.save()

            let result = PersonFactory.prefetch(emails: ["John.Doe+list@GMail.com"], in: context)
            XCTAssertTrue(result["johndoe@gmail.com"] === existing)
        }
    }

    // MARK: - findOrCreate

    func testFindOrCreate_returnsExistingAndImprovesDisplayName() throws {
        try context.performAndWait {
            PersonBuilder().withEmail("alice@example.com").noDisplayName().build(in: context)
            try context.save()

            let person = try PersonFactory.findOrCreate(
                email: "alice@example.com",
                displayName: "Alice Smith",
                in: context
            )
            XCTAssertEqual(person.displayName, "Alice Smith")
            XCTAssertEqual(try personCount(email: "alice@example.com"), 1)
        }
    }

    func testFindOrCreate_improvesDisplayNameOnCacheHit() throws {
        try context.performAndWait {
            // First call creates (and caches) with no display name.
            let created = try PersonFactory.findOrCreate(
                email: "bob@example.com",
                displayName: nil,
                in: context
            )
            // Second call is a cache hit and must still apply the better name.
            let cached = try PersonFactory.findOrCreate(
                email: "bob@example.com",
                displayName: "Bob Jones",
                in: context
            )
            XCTAssertTrue(cached === created)
            XCTAssertEqual(cached.displayName, "Bob Jones")
        }
    }

    func testFindOrCreate_createsOnceAcrossRepeatedCalls() throws {
        try context.performAndWait {
            let first = try PersonFactory.findOrCreate(
                email: "new@example.com",
                displayName: "New Person",
                in: context
            )
            let second = try PersonFactory.findOrCreate(
                email: "new@example.com",
                displayName: "New Person",
                in: context
            )
            XCTAssertTrue(first === second)
            try context.save()
            XCTAssertEqual(try personCount(email: "new@example.com"), 1)
        }
    }

    func testFindOrCreate_normalizesEmail() throws {
        try context.performAndWait {
            let person = try PersonFactory.findOrCreate(
                email: "Jane.Roe+news@GoogleMail.com",
                displayName: "Jane",
                in: context
            )
            XCTAssertEqual(person.email, "janeroe@gmail.com")

            let variant = try PersonFactory.findOrCreate(
                email: "janeroe@gmail.com",
                displayName: nil,
                in: context
            )
            XCTAssertTrue(variant === person)
        }
    }

    // MARK: - lookup

    func testLookup_returnsNilWhenMissingAndPersonWhenPresent() throws {
        try context.performAndWait {
            XCTAssertNil(PersonFactory.lookup(email: "ghost@example.com", in: context))

            let existing = PersonBuilder().withEmail("real@example.com").build(in: context)
            try context.save()
            XCTAssertTrue(PersonFactory.lookup(email: "real@example.com", in: context) === existing)
        }
    }

    // MARK: - Cache invalidation

    func testFindOrCreate_afterRollback_recreatesInsteadOfReturningDetachedObject() throws {
        try context.performAndWait {
            let inserted = try PersonFactory.findOrCreate(
                email: "roll@example.com",
                displayName: nil,
                in: context
            )
            // A failed-save recovery rolls the context back, discarding the
            // unsaved insert; the cache must not resurrect the detached object.
            context.rollback()
            XCTAssertNil(inserted.managedObjectContext)

            let recreated = try PersonFactory.findOrCreate(
                email: "roll@example.com",
                displayName: nil,
                in: context
            )
            XCTAssertFalse(recreated === inserted)
            XCTAssertTrue(recreated.managedObjectContext === context)
        }
    }

    func testFindOrCreate_afterContextReset_refetchesLiveObject() throws {
        try context.performAndWait {
            let original = try PersonFactory.findOrCreate(
                email: "reset@example.com",
                displayName: "Original",
                in: context
            )
            try context.save()

            // Store-teardown paths reset the long-lived context; registered
            // objects are deregistered but userInfo (the cache) survives.
            context.reset()
            XCTAssertNil(original.managedObjectContext)

            let refetched = try PersonFactory.findOrCreate(
                email: "reset@example.com",
                displayName: nil,
                in: context
            )
            XCTAssertFalse(refetched === original)
            XCTAssertTrue(refetched.managedObjectContext === context)
            // The saved row still exists; the miss must re-fetch, not duplicate.
            XCTAssertEqual(try personCount(email: "reset@example.com"), 1)
        }
    }

    func testLookup_afterDeleteAndSave_returnsNilInsteadOfDeletedObject() throws {
        try context.performAndWait {
            let person = try PersonFactory.findOrCreate(
                email: "gone@example.com",
                displayName: nil,
                in: context
            )
            try context.save()

            context.delete(person)
            try context.save()

            XCTAssertNil(PersonFactory.lookup(email: "gone@example.com", in: context))
        }
    }

    func testResetCache_removesContextCacheStorage() throws {
        try context.performAndWait {
            _ = try PersonFactory.findOrCreate(
                email: "drop@example.com",
                displayName: nil,
                in: context
            )
            XCTAssertNotNil(context.userInfo["PersonFactory.personsByEmail"])

            PersonFactory.resetCache(in: context)

            XCTAssertNil(context.userInfo["PersonFactory.personsByEmail"])
        }
    }

    // MARK: - Store reset (sign-out)

    func testResetStore_thenFindOrCreate_returnsLivePersonNotDestroyedStoreZombie() async throws {
        // Sign-out calls CoreDataStack.resetStore(), which destroys the store
        // while the container's viewContext (and its userInfo cache) lives
        // on. A person cached by the optimistic-send path pre-sign-out must
        // not be handed out post-sign-in as a fault against the old store.
        let sqliteStack = TestCoreDataStack(storeKind: .sqlite)
        let stack = CoreDataStack(persistentContainerForTesting: sqliteStack.persistentContainer)
        let viewContext = sqliteStack.persistentContainer.viewContext

        try viewContext.performAndWait {
            _ = try PersonFactory.findOrCreate(
                email: "signout@example.com",
                displayName: "Old Account",
                in: viewContext
            )
            try viewContext.save()
        }

        try await stack.resetStore()

        try viewContext.performAndWait {
            let person = try PersonFactory.findOrCreate(
                email: "signout@example.com",
                displayName: "New Account",
                in: viewContext
            )
            XCTAssertTrue(person.managedObjectContext === viewContext)
            XCTAssertTrue(person.isInserted, "the destroyed store's row is gone; this must be a fresh insert")
            XCTAssertEqual(person.displayName, "New Account")
        }
    }
}
