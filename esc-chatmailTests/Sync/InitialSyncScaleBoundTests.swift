import XCTest
import CoreData
@testable import esc_chatmail

/// Bounds on a re-initial sync over a long-lived install: the listed window
/// is capped and frozen across attempts, and each saved page is released
/// from the run's single sync context instead of staying resident.
final class InitialSyncScaleBoundTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var apiClient: MockGmailAPIClient!
    /// `SyncTimeCalculator` reads the install time from the standard
    /// defaults; snapshot and restore it so other suites see their own.
    private var savedInstallTimestamp: Any?

    private static let myEmail = "me@example.com"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "InitialSyncScaleBoundTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        savedInstallTimestamp = UserDefaults.standard.object(forKey: "installTimestamp")
        testStack = TestCoreDataStack(storeKind: .sqlite)
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        apiClient = MockGmailAPIClient()
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        if let savedInstallTimestamp {
            UserDefaults.standard.set(savedInstallTimestamp, forKey: "installTimestamp")
        } else {
            UserDefaults.standard.removeObject(forKey: "installTimestamp")
        }
        savedInstallTimestamp = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        apiClient = nil
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    /// A held attempt freezes its capped window; the retry lists the same
    /// window even though a fresh computation would now differ; the
    /// advancing attempt deletes the frozen row with the cursor.
    ///
    /// Revert-check: remove the `windowCheckpointStore.load` branch from
    /// `InitialSyncOrchestrator.resolveInitialSyncQuery` and the second
    /// attempt lists from the new install time instead of the frozen start.
    @MainActor
    func testPerformSync_oldInstall_listsCappedWindowFrozenAcrossAttempts() async throws {
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now - 400 * 86_400, forKey: "installTimestamp")
        configureMailbox(pages: [["m1"]])
        apiClient.getMessageErrors["m1"] = APIError.timeout

        let firstResult = try await makeOrchestrator().performSync { _, _ in }

        XCTAssertTrue(firstResult.hadWarnings, "Positive control: the first attempt is held")
        let firstStart = try XCTUnwrap(listedStart())
        XCTAssertEqual(
            firstStart, now - SyncConfig.initialSyncMaxWindow, accuracy: 5,
            "A 400-day-old install must not re-list more than the capped window"
        )
        let frozen = try await frozenWindowStart()
        XCTAssertEqual(frozen.map { Int($0) }, Int(firstStart), "The held attempt commits its window")

        // A fresh computation would now start an hour ago; the retry must not.
        UserDefaults.standard.set(now - 3600, forKey: "installTimestamp")
        apiClient.getMessageErrors["m1"] = nil
        await ModificationTracker.shared.reset()

        let secondResult = try await makeOrchestrator().performSync { _, _ in }

        XCTAssertFalse(secondResult.hadWarnings)
        XCTAssertEqual(listedStart(), firstStart, "The retry lists the frozen window")
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "history-500")
        let cleared = try await frozenWindowStart()
        XCTAssertNil(cleared, "The advancing save deletes the frozen window")
    }

    /// A kept store can hold deferred ledger rows older than the capped
    /// window; the clean advance deletes every deferred row, so the initial
    /// sync must re-fetch them explicitly before advancing.
    ///
    /// Revert-check: drop `deferredLedgerIds` from the retry set in
    /// `InitialSyncOrchestrator.handleSyncCompletion` and "old-deferred" is
    /// never stored while its row is deleted.
    @MainActor
    func testPerformSync_fetchesDeferredLedgerRowsOutsideTheCappedWindow() async throws {
        UserDefaults.standard.set(Date().timeIntervalSince1970 - 400 * 86_400, forKey: "installTimestamp")
        configureMailbox(pages: [["m1"]])
        apiClient.getMessageResponses["old-deferred"] = GmailMessageBuilder()
            .withId("old-deferred")
            .withThreadId("t-old-deferred")
            .withLabels(["INBOX"])
            .withFrom("old@example.com", name: "Old Sender")
            .withTo([Self.myEmail])
            .build()
        try await seedDeferredLedgerRow(id: "old-deferred")

        let result = try await makeOrchestrator().performSync { _, _ in }

        XCTAssertFalse(result.hadWarnings)
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "history-500")
        let context = coreDataStack.newBackgroundContext()
        let (stored, ledgerRows): (Bool, Int) = await context.perform {
            let messages = Message.fetchRequest()
            messages.predicate = NSPredicate(format: "id == %@", "old-deferred")
            let ledger = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            return (
                ((try? context.count(for: messages)) ?? 0) == 1,
                (try? context.count(for: ledger)) ?? -1
            )
        }
        XCTAssertTrue(stored, "The deferred message must be fetched, not just forgotten")
        XCTAssertEqual(ledgerRows, 0)
    }

    /// A deferred ID that the initial listing itself stores must not be
    /// fetched again by the completion retry: a transient failure on that
    /// redundant fetch would hold the run for a message already on disk.
    ///
    /// Revert-check: drop the `resolvedTrackedIds` filter from
    /// `InitialSyncOrchestrator.handleSyncCompletion` and the second full
    /// fetch times out, leaving historyId unset.
    @MainActor
    func testPerformSync_doesNotRefetchADeferredIdItsListingAlreadyStored() async throws {
        UserDefaults.standard.set(Date().timeIntervalSince1970 - 3600, forKey: "installTimestamp")
        configureMailbox(pages: [["m1"]])
        try await seedDeferredLedgerRow(id: "m1")
        let message = try XCTUnwrap(apiClient.getMessageResponses["m1"])
        let fullFetches = FullFetchCounter()
        apiClient.getMessageOperation = { _, format in
            guard format == "full" else { return message }
            guard await fullFetches.increment() == 1 else { throw APIError.timeout }
            return message
        }

        let result = try await makeOrchestrator().performSync { _, _ in }

        let fetchCount = await fullFetches.count
        XCTAssertEqual(fetchCount, 1, "The listing's fetch resolved the deferred ID")
        XCTAssertFalse(result.hadWarnings)
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "history-500")
    }

    /// Each page's saved rows are turned back into faults after the page
    /// save, so the run's context holds at most about one page of realized
    /// messages rather than every message of the run.
    ///
    /// Revert-check: remove `SyncContextPageObjectRelease.release` from the
    /// initial-sync page completion and every message of the run stays
    /// realized in the context.
    @MainActor
    func testPerformSync_releasesEachSavedPageFromTheSyncContext() async throws {
        UserDefaults.standard.set(Date().timeIntervalSince1970 - 3600, forKey: "installTimestamp")
        let pages = (0..<4).map { page in (0..<5).map { "p\(page)-m\($0)" } }
        configureMailbox(pages: pages)
        let syncContext = coreDataStack.newBackgroundContext()

        let result = try await makeOrchestrator(makeSyncContext: { syncContext }).performSync { _, _ in }

        XCTAssertFalse(result.hadWarnings)
        XCTAssertEqual(result.messagesProcessed, 20, "Positive control: every page persisted")
        let realizedMessages = await syncContext.perform {
            syncContext.registeredObjects.filter { $0 is Message && !$0.isFault }.count
        }
        XCTAssertLessThanOrEqual(
            realizedMessages, 5,
            "The sync context must not keep every saved message of the run realized"
        )
    }

    // MARK: - Fixture

    private func configureMailbox(pages: [[String]]) {
        apiClient.profileResponse = GmailProfile(
            emailAddress: Self.myEmail,
            messagesTotal: pages.joined().count,
            threadsTotal: pages.joined().count,
            historyId: "history-500"
        )
        apiClient.labelsResponse = [
            GmailLabel(
                id: "INBOX",
                name: "Inbox",
                messageListVisibility: nil,
                labelListVisibility: nil,
                type: "system"
            )
        ]

        var responses: [String: MessagesListResponse] = [:]
        for (index, ids) in pages.enumerated() {
            let key = index == 0 ? "__first_page__" : "page-\(index + 1)"
            responses[key] = MessagesListResponse(
                messages: ids.map { MessageListItem(id: $0, threadId: "t-\($0)") },
                nextPageToken: index == pages.count - 1 ? nil : "page-\(index + 2)",
                resultSizeEstimate: pages.joined().count
            )
        }
        apiClient.paginatedListMessagesResponses = responses

        for (offset, id) in pages.joined().enumerated() {
            apiClient.getMessageResponses[id] = GmailMessageBuilder()
                .withId(id)
                .withThreadId("t-\(id)")
                .withLabels(["INBOX"])
                .withFrom("sender\(offset)@example.com", name: "Sender \(offset)")
                .withTo([Self.myEmail])
                .withSubject("Subject \(id)")
                .withSnippet("Snippet \(id)")
                .build()
        }
    }

    @MainActor
    private func makeOrchestrator(
        makeSyncContext: (() -> NSManagedObjectContext)? = nil
    ) -> InitialSyncOrchestrator {
        let conversationManager = ConversationManager(
            currentUserEmail: { Self.myEmail }
        )
        let messagePersister = MessagePersister(
            coreDataStack: coreDataStack,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
        return InitialSyncOrchestrator(
            messageFetcher: MessageFetcher(apiClient: apiClient, clock: FakeSyncClock()),
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(Self.myEmail)] }
            ),
            attachmentDownloader: AttachmentDownloader(apiClient: apiClient),
            coreDataStack: coreDataStack,
            failureTracker: SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack),
            performanceLogger: .shared,
            makeSyncContext: makeSyncContext
        )
    }

    private func seedDeferredLedgerRow(id: String) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let row = AbandonedSyncMessage(context: context)
            row.setValue(UUID(), forKey: "id")
            row.setValue(id, forKey: "gmailMessageId")
            row.setValue(Date(timeIntervalSinceNow: -3600), forKey: "abandonedAt")
            row.setValue(Int16(0), forKey: "retryCount")
            row.setValue(AbandonedSyncMessage.State.deferred.rawValue, forKey: "state")
            try context.save()
        }
    }

    /// The `after:` bound of the most recent message-list query.
    private func listedStart() -> TimeInterval? {
        guard let query = apiClient.listMessagesLastQuery,
              let token = query.split(separator: " ").first,
              token.hasPrefix("after:") else {
            return nil
        }
        return TimeInterval(token.dropFirst("after:".count))
    }

    private func frozenWindowStart() async throws -> TimeInterval? {
        try await SyncWindowCheckpointStore.initialSync.load(
            accountEmail: Self.myEmail,
            in: coreDataStack.newBackgroundContext()
        )?.windowStart
    }

    private func fetchAccountHistoryId() async -> String? {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            return (try? context.fetch(request).first)?.historyId
        }
    }
}

/// Counts full-format `getMessage` calls.
private actor FullFetchCounter {
    private(set) var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}
