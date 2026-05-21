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
        AccountBuilder()
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
        AccountBuilder()
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
}

private final class StubSelfAliasProvider: SelfAliasProviding, @unchecked Sendable {
    private let aliases: Set<String>
    private let lock = NSLock()
    private var _searchedEmails: [String] = []

    init(aliases: Set<String>) {
        self.aliases = aliases
    }

    var searchedEmails: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _searchedEmails
    }

    func aliases(knownEmails: [String]) async -> Set<String> {
        lock.lock()
        _searchedEmails = knownEmails
        lock.unlock()
        return aliases
    }
}
