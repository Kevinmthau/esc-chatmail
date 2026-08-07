import XCTest
import CoreData
@testable import esc_chatmail

final class BackgroundSyncStateManagerTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        suiteName = "BackgroundSyncStateManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        testStack = nil
        super.tearDown()
    }

    func testStoreHistoryId_createsAccountWhenMissingIfEmailProvided() async throws {
        let stateManager = makeStateManager()

        try await stateManager.storeHistoryId("history-123", accountEmail: "test@example.com")

        let account = try await fetchAccountSnapshot()
        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.historyId, "history-123")
        XCTAssertEqual(account.aliases, [])
    }

    func testStoreHistoryId_updatesExistingAccountWithoutCreatingDuplicate() async throws {
        AccountBuilder()
            .withEmail("test@example.com")
            .withHistoryId("old-history")
            .build(in: testStack.viewContext)
        try testStack.saveViewContext()

        let stateManager = makeStateManager()
        try await stateManager.storeHistoryId("new-history")

        let account = try await fetchAccountSnapshot()
        let verificationContext = testStack.newBackgroundContext()
        let accountCount = try await verificationContext.perform {
            try verificationContext.count(for: Account.fetchRequest())
        }

        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.historyId, "new-history")
        XCTAssertEqual(accountCount, 1)
    }

    func testContinuationState_roundTripsInitialPartialCheckpointThroughDefaults() throws {
        let stateManager = makeStateManager()
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: nil,
            maxResults: 50,
            startHistoryId: "history-expired",
            watermarkHistoryId: "history-watermark",
            accountEmail: "test@example.com"
        )

        try stateManager.storeContinuationState(continuationState)

        XCTAssertEqual(stateManager.getContinuationState(), continuationState)

        stateManager.clearContinuationState()

        XCTAssertNil(stateManager.getContinuationState())
    }

    func testClearContinuationState_staticHelperRemovesPersistedContinuation() throws {
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: "page-2",
            maxResults: 50,
            startHistoryId: "history-expired",
            watermarkHistoryId: "history-watermark",
            accountEmail: "test@example.com"
        )
        try makeStateManager().storeContinuationState(continuationState)

        BackgroundSyncStateManager.clearContinuationState(in: defaults)

        XCTAssertNil(makeStateManager().getContinuationState())
    }

    func testLegacyPartialContinuation_decodesWithoutWatermarkButIsIncompatible() throws {
        let legacyJSON = #"""
        {
          "mode": "partial",
          "pageToken": "page-2",
          "startHistoryId": "history-expired",
          "query": "after:123 -label:spam",
          "maxResults": 50,
          "accountEmail": "test@example.com"
        }
        """#
        defaults.set(
            try XCTUnwrap(legacyJSON.data(using: .utf8)),
            forKey: "backgroundSync.continuationState"
        )

        let continuationState = try XCTUnwrap(makeStateManager().getContinuationState())

        XCTAssertEqual(continuationState.mode, .partial)
        XCTAssertEqual(continuationState.pageToken, "page-2")
        XCTAssertEqual(continuationState.startHistoryId, "history-expired")
        XCTAssertNil(continuationState.watermarkHistoryId)
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-expired",
                currentAccountEmail: "test@example.com"
            )
        )
    }

    private func makeStateManager() -> BackgroundSyncStateManager {
        let stack = testStack!

        return BackgroundSyncStateManager(
            makeBackgroundContext: { stack.newBackgroundContext() },
            performBackgroundTask: { block in
                _ = try await stack.performBackgroundTask { context in
                    try block(context)
                }
            },
            saveContext: { context in
                guard context.hasChanges else { return }
                try context.save()
            },
            defaults: defaults
        )
    }

    private func fetchAccountSnapshot() async throws -> AccountSnapshot {
        let verificationContext = testStack.newBackgroundContext()
        return try await verificationContext.perform {
            let request: NSFetchRequest<Account> = Account.fetchRequest()
            request.fetchLimit = 1

            guard let account = try verificationContext.fetch(request).first else {
                throw NSError(
                    domain: "BackgroundSyncStateManagerTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected account row to exist"]
                )
            }

            return AccountSnapshot(
                email: account.email,
                historyId: account.historyId,
                aliases: account.aliasesArray
            )
        }
    }
}

private struct AccountSnapshot {
    let email: String
    let historyId: String?
    let aliases: [String]
}
