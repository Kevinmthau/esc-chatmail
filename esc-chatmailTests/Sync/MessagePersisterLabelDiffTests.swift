import XCTest
import CoreData
@testable import esc_chatmail

/// What a refetch of a stored message writes to its labels
/// (`ExistingMessageLabelDiff`, architecture review 2026-11,
/// `sync-persist-path#1`): nothing where Gmail reports what the row holds, and
/// only the difference where it does not.
///
/// The store is SQLite and each update runs in a context that has read
/// nothing, as a sync run's does, so whether a label's `messages` is still a
/// fault after the update says whether the update wrote that label: a write to
/// `Message.labels` makes Core Data read the label's whole membership. The
/// scale harness measures the same thing on a mailbox of S2 size
/// (`ScaleHubFaultTests.testRefetchingAStoredMessageWithUnchangedLabels_readsNeitherHubIntoTheSyncContext`).
///
/// Every update context fails its Label fetches
/// (`EntityFetchFailingContext`), which both says whether the update read a
/// Label and is how the failed read is scripted. `failsFetches` goes off before
/// a test reads a label back.
final class MessagePersisterLabelDiffTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var persister: MessagePersister!
    private var htmlWrites: HTMLWriteCounter!

    /// `@unchecked Sendable`: `count` is guarded by `lock`.
    private final class HTMLWriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }
        func record() {
            lock.lock()
            _count += 1
            lock.unlock()
        }
    }

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
        let htmlWrites = HTMLWriteCounter()
        self.htmlWrites = htmlWrites
        persister = MessagePersister(
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            saveHTML: { _, messageId in
                htmlWrites.record()
                return .savedWithoutWriting(messageId: messageId)
            },
            photoPrefetcher: { _ in }
        )
    }

    override func tearDown() {
        persister = nil
        htmlWrites = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static let messageID = "label-diff-message"

    /// Saves one message holding `storedLabelIDs`, with a Label row for each of
    /// `rowLabelIDs` (which a duplicate may name twice).
    @discardableResult
    private func seedMessage(
        storedLabelIDs: [String],
        rowLabelIDs: [String],
        isUnread: Bool
    ) throws -> [NSManagedObjectID] {
        let context = stack.newBackgroundContext()
        return try context.performAndWait {
            let labels = rowLabelIDs.map { LabelBuilder.custom(id: $0, name: $0, in: context) }
            let conversation = ConversationBuilder.simple(in: context)
            let message = MessageBuilder()
                .withId(Self.messageID)
                .withSnippet("Stored snippet")
                .inConversation(conversation)
                .build(in: context)
            message.isUnread = isUnread
            // The last row of each ID, so a duplicate's first row is not the stored one.
            var storedByID: [String: Label] = [:]
            for label in labels where storedLabelIDs.contains(label.id) {
                storedByID[label.id] = label
            }
            message.labels = Set(storedByID.values)
            try context.save()
            return labels.map(\.objectID)
        }
    }

    private func makeUpdateContext() -> EntityFetchFailingContext {
        let context = EntityFetchFailingContext(
            failingEntityName: "Label",
            coordinator: stack.persistentContainer.persistentStoreCoordinator
        )
        context.performAndWait {
            context.retainsRegisteredObjects = true
        }
        return context
    }

    private func refetch(labelIDs: [String], isUnread: Bool, snippet: String = "Stored snippet") -> ProcessedMessage {
        ProcessedMessage(
            id: Self.messageID,
            gmThreadId: "thread-label-diff",
            snippet: snippet,
            cleanedSnippet: snippet,
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: nil,
            labelIds: labelIDs,
            isUnread: isUnread,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )
    }

    private func update(
        _ processedMessage: ProcessedMessage,
        in context: NSManagedObjectContext
    ) async -> ExistingMessageUpdateOutcome {
        await persister.updateExistingMessageOutcome(
            processedMessage,
            labelIds: nil,
            myAliases: [],
            modificationTransaction: nil,
            reroutedSourceRollupBuffer: nil,
            remoteCommittedSendMutation: nil,
            in: context
        )
    }

    private struct LabelState: Equatable {
        let storedLabelObjectIDs: Set<NSManagedObjectID>
        let storedLabelIDs: Set<String>
        let isUnread: Bool
        /// Label ID to whether that label's `messages` is still a fault, for
        /// every Label row.
        let membersAreFault: [NSManagedObjectID: Bool]
    }

    /// Reads, in the update context, the message as the update left it and
    /// whether each label's members were read.
    private func labelState(in context: EntityFetchFailingContext) async throws -> LabelState {
        context.failsFetches = false
        return try await context.perform {
            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = MessagePredicates.id(Self.messageID)
            let message = try XCTUnwrap(try context.fetch(messageRequest).first)
            let labels = try context.fetch(Label.fetchRequest())
            return LabelState(
                storedLabelObjectIDs: Set((message.labels ?? []).map(\.objectID)),
                storedLabelIDs: Set((message.labels ?? []).map(\.id)),
                isUnread: message.isUnread,
                membersAreFault: Dictionary(uniqueKeysWithValues: labels.map {
                    ($0.objectID, $0.hasFault(forRelationshipNamed: "messages"))
                })
            )
        }
    }

    // MARK: - Tests

    /// Revert-check: `ExistingMessageLabelDiff` in
    /// `MessagePersister.performExistingMessageUpdate`. With the old
    /// `existingMessage.labels = nil` and re-add, the update reads both
    /// labels' members and fetches the Label rows.
    func testRefetch_unchangedLabels_readsNoLabelAndWritesNone() async throws {
        let labelObjectIDs = try seedMessage(
            storedLabelIDs: ["INBOX", "UNREAD"],
            rowLabelIDs: ["INBOX", "UNREAD"],
            isUnread: true
        )
        let context = makeUpdateContext()

        let outcome = await update(refetch(labelIDs: ["INBOX", "UNREAD"], isUnread: true), in: context)

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(context.failedFetches, 0, "An unchanged refetch read Label rows")
        let state = try await labelState(in: context)
        XCTAssertEqual(state.storedLabelObjectIDs, Set(labelObjectIDs))
        XCTAssertTrue(state.isUnread)
        for objectID in labelObjectIDs {
            XCTAssertEqual(state.membersAreFault[objectID], true, "An unchanged label was written")
        }
    }

    /// Revert-check: `ExistingMessageLabelDiff` (the kept INBOX). With the old
    /// replace-all the INBOX label is removed and added back, and its members
    /// are read.
    func testRefetch_changedLabels_landExactlyAndLeaveTheKeptLabelUnwritten() async throws {
        let labelObjectIDs = try seedMessage(
            storedLabelIDs: ["INBOX", "UNREAD", "CATEGORY_UPDATES"],
            rowLabelIDs: ["INBOX", "UNREAD", "CATEGORY_UPDATES", "STARRED"],
            isUnread: true
        )
        let inboxObjectID = labelObjectIDs[0]
        let context = makeUpdateContext()
        context.failsFetches = false

        let outcome = await update(refetch(labelIDs: ["INBOX", "STARRED"], isUnread: false), in: context)

        XCTAssertEqual(outcome, .updated)
        let state = try await labelState(in: context)
        XCTAssertEqual(state.storedLabelIDs, ["INBOX", "STARRED"])
        XCTAssertFalse(state.isUnread)
        XCTAssertEqual(state.membersAreFault[inboxObjectID], true, "The kept INBOX label was written")
        try await context.perform { try context.save() }
        try XCTAssertEqual(storedLabelIDs(), ["INBOX", "STARRED"])
    }

    /// A label Gmail reports that this store has no row for (made in Gmail
    /// since the last label sync) cannot be added, so it is no difference.
    ///
    /// Revert-check: the `missingIDs` read in `ExistingMessageLabelDiff.plan`.
    /// Diff the reported IDs as strings instead (rewrite whenever they are not
    /// the stored IDs) and every refetch of this message rewrites INBOX.
    func testRefetch_reportedLabelWithNoRow_isNoDifference() async throws {
        let labelObjectIDs = try seedMessage(
            storedLabelIDs: ["INBOX"],
            rowLabelIDs: ["INBOX"],
            isUnread: false
        )
        let context = makeUpdateContext()
        context.failsFetches = false

        let outcome = await update(refetch(labelIDs: ["INBOX", "Label_not_synced_yet"], isUnread: false), in: context)

        XCTAssertEqual(outcome, .updated)
        let state = try await labelState(in: context)
        XCTAssertEqual(state.storedLabelObjectIDs, Set(labelObjectIDs))
        XCTAssertEqual(state.membersAreFault[labelObjectIDs[0]], true, "INBOX was written for a label with no row")
    }

    /// Two Label rows for one ID are legal until the merge pass repairs them.
    /// The message keeps the duplicate it holds, rather than trading it for
    /// whichever row a fetch returns first.
    ///
    /// Label reads are let through here, so that a diff which reads the rows
    /// can trade one for the other; that no read is made is the unchanged
    /// refetch's test.
    ///
    /// Revert-check: the `storedLabels.map(\.id)` subtraction in
    /// `ExistingMessageLabelDiff.plan`. Diff against the fetched rows instead
    /// and the stored duplicate (the second row) is traded for whichever row
    /// SQLite returns first, writing both labels. HONEST SCOPE: which row
    /// comes first is SQLite's choice, so that diff fails here by chance: 11
    /// of 20 iterations (`-test-iterations 20`, iOS 27.0 simulator,
    /// 2026-11-28). The same mutation fails
    /// `testRefetch_unchangedLabels_readsNoLabelAndWritesNone` every time: a
    /// diff against the fetched rows reads the Label rows, which that test's
    /// context refuses.
    func testRefetch_duplicateLabelRows_keepTheStoredDuplicate() async throws {
        let labelObjectIDs = try seedMessage(
            storedLabelIDs: ["INBOX"],
            rowLabelIDs: ["INBOX", "INBOX"],
            isUnread: false
        )
        let storedDuplicate = labelObjectIDs[1]
        let context = makeUpdateContext()
        context.failsFetches = false

        let outcome = await update(refetch(labelIDs: ["INBOX"], isUnread: false), in: context)

        XCTAssertEqual(outcome, .updated)
        let state = try await labelState(in: context)
        XCTAssertEqual(state.storedLabelObjectIDs, [storedDuplicate])
        XCTAssertEqual(state.membersAreFault[storedDuplicate], true)
    }

    /// A Label read that fails is not "none of these labels has a row": the
    /// message is reported failed, which holds the cursor, and nothing about
    /// the row changes, its labels, its snippet and its body file included.
    ///
    /// Revert-check: `fetchLabelsByIdsOrThrow` in
    /// `MessagePersister.performExistingMessageUpdate`. Read the failure as an
    /// empty answer (`(try? …) ?? [:]`, as `fetchLabelsByIds` did until
    /// 2026-11-28) and the update goes ahead without the new label, writes the
    /// body and the new snippet, and reports the message persisted.
    func testSaveMessages_failedLabelRead_reportsFailedAndLeavesTheRowAsItWas() async throws {
        let labelObjectIDs = try seedMessage(
            storedLabelIDs: ["INBOX"],
            rowLabelIDs: ["INBOX", "STARRED"],
            isUnread: false
        )
        let context = makeUpdateContext()
        let gmailMessage = GmailMessageBuilder()
            .withId(Self.messageID)
            .withThreadId("thread-label-diff")
            .withLabels(["INBOX", "STARRED"])
            .withFrom("sender@example.com", name: "Sender")
            .withTo(["me@example.com"])
            .withSubject("Subject")
            .withSnippet("A new snippet")
            .withBodyHtml("<p>A new body</p>")
            .build()

        let report = try await persister.saveMessages([gmailMessage], myAliases: ["me@example.com"], in: context)

        XCTAssertEqual(report.failedIds, [Self.messageID])
        XCTAssertEqual(report.persistedIds, [])
        XCTAssertEqual(context.failedFetches, 1)
        XCTAssertEqual(htmlWrites.count, 0, "The body was written before the labels were read")
        let hasChanges = await context.perform { context.hasChanges }
        XCTAssertFalse(hasChanges, "The row was changed although its update failed")
        let state = try await labelState(in: context)
        XCTAssertEqual(state.storedLabelObjectIDs, [labelObjectIDs[0]])
        let snippet = try await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(Self.messageID)
            return try XCTUnwrap(try context.fetch(request).first).snippet
        }
        XCTAssertEqual(snippet, "Stored snippet")
    }

    /// A new message whose Label read fails is not a message with no labels:
    /// it is reported failed, which holds the cursor, and nothing is written
    /// for it, not its body, not a conversation, not a row.
    ///
    /// Revert-check: `fetchLabelsByIdsOrThrow` at the top of
    /// `MessagePersister.createNewMessage`. Read the failure as an empty
    /// answer and the message is stored with no labels and reported
    /// persisted.
    func testSaveMessages_newMessage_failedLabelRead_reportsFailedAndWritesNothing() async throws {
        let context = makeUpdateContext()
        try context.performAndWait {
            _ = LabelBuilder.inboxLabel(in: context)
            try context.save()
        }
        let gmailMessage = GmailMessageBuilder()
            .withId("new-message-label-read-fails")
            .withThreadId("thread-new-label-read-fails")
            .withLabels(["INBOX"])
            .withFrom("sender@example.com", name: "Sender")
            .withTo(["me@example.com"])
            .withSubject("Subject")
            .withSnippet("A new message")
            .withBodyHtml("<p>A new body</p>")
            .build()

        let report = try await persister.saveMessages([gmailMessage], myAliases: ["me@example.com"], in: context)

        XCTAssertEqual(report.failedIds, ["new-message-label-read-fails"])
        XCTAssertEqual(report.persistedIds, [])
        XCTAssertEqual(context.failedFetches, 1)
        XCTAssertEqual(htmlWrites.count, 0, "The body was written before the labels were read")
        let hasChanges = await context.perform { context.hasChanges }
        XCTAssertFalse(hasChanges, "Something was inserted for a message that failed")
        let readContext = stack.newBackgroundContext()
        let storedCounts = try readContext.performAndWait {
            (try readContext.count(for: Message.fetchRequest()), try readContext.count(for: Conversation.fetchRequest()))
        }
        XCTAssertEqual(storedCounts.0, 0)
        XCTAssertEqual(storedCounts.1, 0, "Routing made a conversation for a message that failed")
    }

    /// The stored message's label IDs, read in a context of its own.
    private func storedLabelIDs() throws -> Set<String> {
        let context = stack.newBackgroundContext()
        return try context.performAndWait {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(Self.messageID)
            let message = try XCTUnwrap(try context.fetch(request).first)
            return Set((message.labels ?? []).map(\.id))
        }
    }
}
