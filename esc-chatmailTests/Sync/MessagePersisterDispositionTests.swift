import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the per-ID persistence dispositions that gate cursor advancement:
/// every saved message lands in exactly one report bucket, and the failure
/// modes that used to be silent (routing failure, failed excluded-row delete,
/// failed existing-message lookup) surface as `.failed` / `.lookupFailed`.
final class MessagePersisterDispositionTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!

    private static let myEmail = "me@example.com"

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    @MainActor
    private func makePersister(
        conversationCreationError: Error? = nil,
        coreDataStack: CoreDataStack? = nil,
        messageProcessor: MessageProcessor = MessageProcessor()
    ) -> MessagePersister {
        let conversationManager: ConversationManager
        if let conversationCreationError {
            conversationManager = ConversationManager(
                findOrCreateConversationHandler: { _, _, _, _, _, _ in
                    throw conversationCreationError
                },
                currentUserEmail: { Self.myEmail }
            )
        } else {
            conversationManager = ConversationManager(currentUserEmail: { Self.myEmail })
        }
        return MessagePersister(
            coreDataStack: coreDataStack ?? self.coreDataStack,
            messageProcessor: messageProcessor,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
    }

    private func makeFullMessage(id: String, labels: [String] = ["INBOX"]) -> GmailMessage {
        GmailMessageBuilder()
            .withId(id)
            .withThreadId("t-\(id)")
            .withLabels(labels)
            .withFrom("alice@example.com", name: "Alice Smith")
            .withTo([Self.myEmail])
            .withSubject("Subject \(id)")
            .withSnippet("Snippet \(id)")
            .build()
    }

    /// A message whose body Gmail returns by attachmentId (bodies >~25KB),
    /// forcing the processor's large-body fetch.
    private func makeLargeBodyMessage(id: String) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "t-\(id)",
            labelIds: ["INBOX"],
            snippet: "Snippet \(id)",
            historyId: nil,
            internalDate: "1700000000000",
            payload: MessagePart(
                partId: "",
                mimeType: "text/plain",
                filename: nil,
                headers: [
                    MessageHeader(name: "From", value: "Alice Smith <alice@example.com>"),
                    MessageHeader(name: "To", value: Self.myEmail),
                    MessageHeader(name: "Subject", value: "Subject \(id)"),
                    MessageHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")
                ],
                body: MessageBody(size: 30_000, data: nil, attachmentId: "att-\(id)"),
                parts: nil
            ),
            sizeEstimate: 30_000
        )
    }

    // MARK: - Large-body fetch failures

    @MainActor
    func testRateLimitedLargeBodyFetchReportsFailedWithoutPersisting() async throws {
        let persister = makePersister(
            messageProcessor: MessageProcessor(fetchAttachmentData: { _, _ in
                throw APIError.rateLimited(retryAfter: nil)
            })
        )
        let context = coreDataStack.newBackgroundContext()

        let report = try await persister.saveMessages(
            [makeLargeBodyMessage(id: "m-rate-limited")],
            myAliases: [Self.myEmail],
            in: context
        )

        XCTAssertEqual(
            report.failedIds, ["m-rate-limited"],
            "A transient body-fetch failure must block the cursor, not persist an empty body"
        )
        XCTAssertTrue(report.persistedIds.isEmpty)
        XCTAssertTrue(report.unprocessableIds.isEmpty)

        let rowCount: Int = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "m-rate-limited")
            return (try? context.count(for: request)) ?? -1
        }
        XCTAssertEqual(rowCount, 0, "No body-less row may be created for a failed body fetch")
    }

    @MainActor
    func testQuotaExhaustedLargeBodyFetchAbortsTheBatchWithNoVerdict() async throws {
        let persister = makePersister(
            messageProcessor: MessageProcessor(fetchAttachmentData: { _, _ in
                throw APIError.quotaExhausted("Daily Limit Exceeded")
            })
        )
        let context = coreDataStack.newBackgroundContext()

        do {
            _ = try await persister.saveMessages(
                [makeFullMessage(id: "m-inline"), makeLargeBodyMessage(id: "m-quota")],
                myAliases: [Self.myEmail],
                in: context
            )
            XCTFail("Quota exhaustion is account-scoped and must abort the batch")
        } catch let error as APIError {
            guard case .quotaExhausted = error else {
                return XCTFail("Expected quotaExhausted, got \(error)")
            }
        }

        let rowCount: Int = await context.perform {
            let request = Message.fetchRequest()
            return (try? context.count(for: request)) ?? -1
        }
        XCTAssertEqual(rowCount, 0, "An aborted batch must leave no per-message verdicts or rows")
    }

    @MainActor
    func testAuthenticationFailuresDuringLargeBodyFetchAbortWithNoVerdict() async throws {
        for id in ["m-auth", "m-revoked"] {
            let persister = makePersister(
                messageProcessor: MessageProcessor(fetchAttachmentData: { _, _ in
                    if id == "m-auth" {
                        throw APIError.authenticationError
                    }
                    throw APIError.credentialsRevoked
                })
            )
            let context = coreDataStack.newBackgroundContext()

            do {
                _ = try await persister.saveMessages(
                    [makeFullMessage(id: "m-inline"), makeLargeBodyMessage(id: id)],
                    myAliases: [Self.myEmail],
                    in: context
                )
                XCTFail("Account authentication failures must abort the whole batch")
            } catch let error as APIError {
                XCTAssertTrue(error.isAccountScopedSyncAbort)
            }

            let rowCount: Int = await context.perform {
                let request = Message.fetchRequest()
                return (try? context.count(for: request)) ?? -1
            }
            XCTAssertEqual(
                rowCount,
                0,
                "An account outage must not create rows or per-message failure verdicts"
            )
        }
    }

    @MainActor
    func testCancelledBodyFetchThrowsWithoutVerdict() async throws {
        let persister = makePersister(
            messageProcessor: MessageProcessor(fetchAttachmentData: { _, _ in
                throw CancellationError()
            })
        )
        let context = coreDataStack.newBackgroundContext()

        do {
            _ = try await persister.saveMessages(
                [makeLargeBodyMessage(id: "m-cancelled")],
                myAliases: [Self.myEmail],
                in: context
            )
            XCTFail("A cancelled run proves nothing about the message and must not yield a verdict")
        } catch is CancellationError {
            // Expected: no per-message verdict for a cancelled run.
        }

        let rowCount: Int = await context.perform {
            let request = Message.fetchRequest()
            return (try? context.count(for: request)) ?? -1
        }
        XCTAssertEqual(rowCount, 0)
    }

    @MainActor
    func testMissingLargeBodyAttachmentStillPersistsMessage() async throws {
        let persister = makePersister(
            messageProcessor: MessageProcessor(fetchAttachmentData: { _, _ in
                throw APIError.notFound("attachment")
            })
        )
        let context = coreDataStack.newBackgroundContext()

        let report = try await persister.saveMessages(
            [makeLargeBodyMessage(id: "m-gone-attachment")],
            myAliases: [Self.myEmail],
            in: context
        )

        XCTAssertEqual(
            report.persistedIds, ["m-gone-attachment"],
            "A 404'd attachment is gone for good; the message must persist without it"
        )
        XCTAssertTrue(report.failedIds.isEmpty)

        let persistedRow: (found: Bool, bodyText: String?) = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "m-gone-attachment")
            guard let row = (try? context.fetch(request))?.first else { return (false, nil) }
            return (true, row.bodyText)
        }
        XCTAssertTrue(persistedRow.found)
        XCTAssertNil(persistedRow.bodyText)
    }

    @MainActor
    func testSuccessfulCreateReportsPersisted() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-ok")],
            myAliases: [Self.myEmail],
            in: context
        )

        XCTAssertEqual(report.persistedIds, ["m-ok"])
        XCTAssertTrue(report.failedIds.isEmpty)
        XCTAssertTrue(report.excludedIds.isEmpty)
        XCTAssertTrue(report.unprocessableIds.isEmpty)
    }

    @MainActor
    func testExcludedMailboxMessageReportsExcludedAndRemovesLocalRow() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()

        // Seed a local row that the SPAM-labeled arrival must remove.
        _ = try await persister.saveMessages(
            [makeFullMessage(id: "m-spam")],
            myAliases: [Self.myEmail],
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-spam", labels: ["SPAM"])],
            myAliases: [Self.myEmail],
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        XCTAssertEqual(report.excludedIds, ["m-spam"])
        XCTAssertTrue(report.failedIds.isEmpty)

        let remaining: Int = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "m-spam")
            request.includesPendingChanges = false
            return (try? context.count(for: request)) ?? -1
        }
        XCTAssertEqual(remaining, 0, "The excluded message's local row must be gone")
    }

    @MainActor
    func testSaveMessage_excludedCommittedSendConsumesOptimisticGraphAtomically() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()
        let optimisticID = "optimistic-exact-excluded"
        let remoteID = "remote-exact-excluded"
        try await seedOptimisticSend(
            optimisticID: optimisticID,
            remoteMessageID: remoteID,
            in: context
        )

        let disposition = try await persister.saveMessage(
            makeFullMessage(id: remoteID, labels: ["SENT", "TRASH"]),
            myAliases: [Self.myEmail],
            in: context
        )

        XCTAssertEqual(disposition, .excluded)
        let stateBeforeSave = try await durableOptimisticState(
            optimisticID: optimisticID
        )
        XCTAssertEqual(
            stateBeforeSave,
            OptimisticState(messages: 1, mutationRecords: 1, conversations: 1),
            "The replacement must remain entirely pending until the caller commits its cursor save"
        )

        try await coreDataStack.saveAsync(context: context)

        let stateAfterSave = try await durableOptimisticState(
            optimisticID: optimisticID
        )
        XCTAssertEqual(
            stateAfterSave,
            OptimisticState(messages: 0, mutationRecords: 0, conversations: 0)
        )
    }

    @MainActor
    func testSaveMessages_excludedDeterministicEchoConsumesOnlyMatchingLocalMarker() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()
        let optimisticID = "optimistic-marker-excluded"
        let matchingRemoteID = "remote-marker-excluded"
        let unrelatedRemoteID = "unrelated-excluded"
        try await seedOptimisticSend(
            optimisticID: optimisticID,
            remoteMessageID: OutboundSendRemoteState.ambiguousMessageID,
            in: context
        )
        let matchingEcho = GmailMessageBuilder()
            .withId(matchingRemoteID)
            .withThreadId("remote-marker-thread")
            .withLabels(["SENT", "SPAM"])
            .withMessageId(
                MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
            )
            .build()
        let unrelatedExcludedMessage = GmailMessageBuilder()
            .withId(unrelatedRemoteID)
            .withThreadId("unrelated-thread")
            .withLabels(["SPAM"])
            .withMessageId("<unrelated@example.com>")
            .build()

        let report = try await persister.saveMessages(
            [unrelatedExcludedMessage, matchingEcho],
            myAliases: [Self.myEmail],
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        XCTAssertEqual(Set(report.excludedIds), [matchingRemoteID, unrelatedRemoteID])
        XCTAssertTrue(report.failedIds.isEmpty)
        let finalState = try await durableOptimisticState(
            optimisticID: optimisticID
        )
        XCTAssertEqual(
            finalState,
            OptimisticState(messages: 0, mutationRecords: 0, conversations: 0)
        )
    }

    @MainActor
    // Revert-check: fails if the create-new path stops calling
    // `preserveSupersededOptimisticContentIfNeeded` before consumption — the
    // snippet-truncated echo row would keep Gmail's preview text instead of
    // the authored bodyText/cleanedSnippet/chatPreviewText for both the
    // in-flight and ambiguous marker states this test drives end-to-end.
    func testSaveMessage_deterministicLocalMarkerEchoPreservesOptimisticAuthoredContent() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()
        let authoredBody = """
        Can we please see alts for:

        Primary bedroom drapery
        Kitchen backsplash

        Thank you!
        """
        let authoredCleanedSnippet =
            "Can we please see alts for: Primary bedroom drapery Kitchen backsplash Thank you!"
        let snippetOnlyBody = "Can we please see alts for:"
        let markerCases = [
            ("in-flight", OutboundSendRemoteState.inFlightMessageID),
            ("ambiguous", OutboundSendRemoteState.ambiguousMessageID)
        ]

        for (suffix, remoteState) in markerCases {
            let optimisticID = "optimistic-body-\(suffix)"
            let remoteID = "remote-body-\(suffix)"
            try await seedOptimisticSend(
                optimisticID: optimisticID,
                remoteMessageID: remoteState,
                authoredBody: authoredBody,
                cleanedSnippet: authoredCleanedSnippet,
                chatPreviewText: authoredBody,
                in: context
            )

            let echo = GmailMessageBuilder()
                .withId(remoteID)
                .withThreadId("remote-body-thread-\(suffix)")
                .sent()
                .withFrom(Self.myEmail, name: "Me")
                .withTo(["friend@example.com"])
                .withMessageId(
                    MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
                )
                .withSnippet(snippetOnlyBody)
                .withBodyText(snippetOnlyBody)
                .build()

            let disposition = try await persister.saveMessage(
                echo,
                myAliases: [Self.myEmail],
                in: context
            )
            XCTAssertEqual(disposition, .persisted, suffix)
            try await coreDataStack.saveAsync(context: context)

            let state = try await context.perform {
                let remoteRequest = Message.fetchRequest()
                remoteRequest.predicate = MessagePredicates.id(remoteID)
                remoteRequest.fetchLimit = 1
                let remoteMessage = try XCTUnwrap(context.fetch(remoteRequest).first)

                let optimisticRequest = Message.fetchRequest()
                optimisticRequest.predicate = MessagePredicates.id(optimisticID)

                let mutationRequest = OutboundSendMutationRecord.fetchRequest()
                mutationRequest.predicate = NSPredicate(
                    format: "id == %@",
                    optimisticID
                )

                return (
                    bodyText: remoteMessage.bodyText,
                    cleanedSnippet: remoteMessage.cleanedSnippet,
                    chatPreviewText: remoteMessage.chatPreviewText,
                    optimisticCount: try context.count(for: optimisticRequest),
                    mutationCount: try context.count(for: mutationRequest)
                )
            }

            XCTAssertEqual(state.bodyText, authoredBody, suffix)
            XCTAssertEqual(state.cleanedSnippet, authoredCleanedSnippet, suffix)
            XCTAssertEqual(state.chatPreviewText, authoredBody, suffix)
            XCTAssertEqual(state.optimisticCount, 0, suffix)
            XCTAssertEqual(state.mutationCount, 0, suffix)
        }
    }

    // Revert-check: fails if the update path's preview overwrite stops routing
    // through `richerSupersededPreview` when `shouldPreserveOutgoingLocalBodyText`
    // holds — re-syncing the same snippet-truncated echo would revert
    // cleanedSnippet/chatPreviewText to Gmail's truncated preview while
    // bodyText keeps the authored text, resurrecting the truncated bubble the
    // create path's preservation just fixed.
    @MainActor
    func testSaveMessage_truncatedEchoRefetchKeepsPreservedPreviews() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()
        let authoredBody = "Line one\n\nLine two\n\nThank you!"
        let authoredCleanedSnippet = "Line one Line two Thank you!"
        let snippetOnlyBody = "Line one"
        let optimisticID = "optimistic-refetch"
        let remoteID = "remote-refetch"
        try await seedOptimisticSend(
            optimisticID: optimisticID,
            remoteMessageID: OutboundSendRemoteState.inFlightMessageID,
            authoredBody: authoredBody,
            cleanedSnippet: authoredCleanedSnippet,
            chatPreviewText: authoredBody,
            in: context
        )

        let echo = GmailMessageBuilder()
            .withId(remoteID)
            .withThreadId("remote-refetch-thread")
            .sent()
            .withFrom(Self.myEmail, name: "Me")
            .withTo(["friend@example.com"])
            .withMessageId(
                MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
            )
            .withSnippet(snippetOnlyBody)
            .withBodyText(snippetOnlyBody)
            .build()

        // First arrival: the create path preserves the authored content and
        // consumes the optimistic row.
        _ = try await persister.saveMessage(echo, myAliases: [Self.myEmail], in: context)
        try await coreDataStack.saveAsync(context: context)

        // Refetch of the SAME truncated echo takes the update path, which
        // must not undo the preservation.
        let disposition = try await persister.saveMessage(
            echo,
            myAliases: [Self.myEmail],
            in: context
        )
        XCTAssertEqual(disposition, .persisted)
        try await coreDataStack.saveAsync(context: context)

        let state = try await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(remoteID)
            request.fetchLimit = 1
            let remoteMessage = try XCTUnwrap(context.fetch(request).first)
            return (
                bodyText: remoteMessage.bodyText,
                cleanedSnippet: remoteMessage.cleanedSnippet,
                chatPreviewText: remoteMessage.chatPreviewText
            )
        }

        XCTAssertEqual(state.bodyText, authoredBody)
        XCTAssertEqual(state.cleanedSnippet, authoredCleanedSnippet)
        XCTAssertEqual(state.chatPreviewText, authoredBody)
    }

    @MainActor
    func testUnprocessablePayloadReportsUnprocessable() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()

        // No payload/headers: MessageProcessor deterministically returns nil.
        let raw = GmailMessage(
            id: "m-raw",
            threadId: "t-raw",
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
        let report = try await persister.saveMessages([raw], myAliases: [Self.myEmail], in: context)

        XCTAssertEqual(report.unprocessableIds, ["m-raw"])
        XCTAssertTrue(report.failedIds.isEmpty)
        XCTAssertTrue(report.persistedIds.isEmpty)
    }

    @MainActor
    func testConversationRoutingFailureReportsFailed() async throws {
        struct RoutingFailure: Error {}
        let persister = makePersister(conversationCreationError: RoutingFailure())
        let context = coreDataStack.newBackgroundContext()

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-doomed")],
            myAliases: [Self.myEmail],
            in: context
        )

        XCTAssertEqual(report.failedIds, ["m-doomed"], "A routing failure is a blocking per-message failure")
        XCTAssertTrue(report.persistedIds.isEmpty)
    }

    /// A failed existing-message lookup must be `.lookupFailed` — creating
    /// anyway could insert a duplicate of a row that exists but could not be
    /// read.
    @MainActor
    func testFailedLookupReportsLookupFailedNotNotPresent() async throws {
        let persister = makePersister()
        let failingContext = try FailingReadStore.makeFailingContext()

        let processed = try await persister.prepareMessage(
            makeFullMessage(id: "m-unreadable"),
            myAliases: [Self.myEmail]
        )
        guard case .processed(let processedMessage) = processed else {
            return XCTFail("Fixture must prepare successfully")
        }

        let outcome = await persister.updateExistingMessageOutcome(
            processedMessage,
            labelIds: nil,
            myAliases: [Self.myEmail],
            modificationTransaction: nil,
            reroutedSourceRollupBuffer: nil,
            remoteCommittedSendMutation: nil,
            in: failingContext
        )

        XCTAssertEqual(outcome, .lookupFailed)
    }

    /// The full pipeline mapping: a failed lookup surfaces as `.failed` in
    /// the report (not persisted, not silently created).
    @MainActor
    func testFailedLookupSurfacesAsFailedInReport() async throws {
        let persister = makePersister()
        let failingContext = try FailingReadStore.makeFailingContext()

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-unreadable")],
            myAliases: [Self.myEmail],
            in: failingContext
        )

        XCTAssertEqual(report.failedIds, ["m-unreadable"])
        XCTAssertTrue(report.persistedIds.isEmpty)
    }

    private struct OptimisticState: Equatable {
        let messages: Int
        let mutationRecords: Int
        let conversations: Int
    }

    private func seedOptimisticSend(
        optimisticID: String,
        remoteMessageID: String,
        authoredBody: String = "This is the full body text of the test message.",
        cleanedSnippet: String? = nil,
        chatPreviewText: String? = nil,
        in context: NSManagedObjectContext
    ) async throws {
        try await context.perform {
            let conversation = ConversationBuilder()
                .withDisplayName("Optimistic send")
                .withSnippet("Authored body")
                .withLastMessageDate(Date())
                .visible()
                .build(in: context)
            let message = MessageBuilder()
                .withId(optimisticID)
                .withThreadId("optimistic-thread")
                .withSnippet("Authored body")
                .withBody(authoredBody)
                .fromMe()
                .inConversation(conversation)
                .build(in: context)
            message.cleanedSnippet = cleanedSnippet
            message.chatPreviewText = chatPreviewText
            message.messageId = MimeBuilder.messageId(
                forOptimisticMessageID: optimisticID
            )
            try context.obtainPermanentIDs(for: [conversation, message])

            let record = context.insertTestObject(OutboundSendMutationRecord.self)
            record.id = optimisticID
            record.createdAt = Date()
            record.hidden = false
            record.newlyInsertedConversation = true
            record.conversationId = conversation.id
            record.conversationURI = conversation.objectID.uriRepresentation().absoluteString
            record.remoteCommittedMessageId = remoteMessageID
            record.remoteCommittedThreadId = OutboundSendRemoteState.isLocalMarker(remoteMessageID)
                ? nil
                : "remote-thread"
            try context.save()
        }
    }

    private func durableOptimisticState(
        optimisticID: String
    ) async throws -> OptimisticState {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = MessagePredicates.id(optimisticID)
            messageRequest.includesPendingChanges = false

            let mutationRequest = OutboundSendMutationRecord.fetchRequest()
            mutationRequest.predicate = NSPredicate(format: "id == %@", optimisticID)
            mutationRequest.includesPendingChanges = false

            let conversationRequest = Conversation.fetchRequest()
            conversationRequest.includesPendingChanges = false

            return OptimisticState(
                messages: try context.count(for: messageRequest),
                mutationRecords: try context.count(for: mutationRequest),
                conversations: try context.count(for: conversationRequest)
            )
        }
    }
}
