import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class VirtualScrollStateTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.viewContext
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    func testLoadMessagePage_returnsOrderedObjectIDsFromBackgroundContext() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 6)
        let page = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 1..<4,
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(page.totalCount, 6)
        XCTAssertEqual(page.messageIDs, Array(messages[1..<4]).map(\.objectID))
    }

    func testLoadMessagePage_emptyRangeReturnsCountWithoutFetchingMessageIDs() async throws {
        let (conversation, _) = try makeConversationWithMessages(count: 6)
        let page = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 0..<0,
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(page.totalCount, 6)
        XCTAssertTrue(page.messageIDs.isEmpty)
    }

    func testLoadMessagePage_omitsExcludedLabelMessagesFromPageIDs() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let excludedLabels = makeExcludedLabels()
        let visible0 = makeMessage(id: "virtual-scroll-visible-0", date: 0, conversation: conversation)
        let spam = makeMessage(id: "virtual-scroll-spam", date: 1, conversation: conversation)
        spam.addToLabels(excludedLabels.spam)
        let visible1 = makeMessage(id: "virtual-scroll-visible-1", date: 2, conversation: conversation)
        let draft = makeMessage(id: "virtual-scroll-draft", date: 3, conversation: conversation)
        draft.addToLabels(excludedLabels.draft)
        let trash = makeMessage(id: "virtual-scroll-trash", date: 4, conversation: conversation)
        trash.addToLabels(excludedLabels.trash)
        let visible2 = makeMessage(id: "virtual-scroll-visible-2", date: 5, conversation: conversation)

        try viewContext.save()

        let page = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 0..<10,
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(page.totalCount, 3)
        XCTAssertEqual(page.messageIDs, [visible0, visible1, visible2].map(\.objectID))
    }

    func testLoadMessagePage_omitsExcludedLabelMessagesFromTotalCount() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let excludedLabels = makeExcludedLabels()
        _ = makeMessage(id: "virtual-scroll-count-visible-0", date: 0, conversation: conversation)
        let draft = makeMessage(id: "virtual-scroll-count-draft", date: 1, conversation: conversation)
        draft.addToLabels(excludedLabels.draft)
        _ = makeMessage(id: "virtual-scroll-count-visible-1", date: 2, conversation: conversation)
        let trash = makeMessage(id: "virtual-scroll-count-trash", date: 3, conversation: conversation)
        trash.addToLabels(excludedLabels.trash)

        try viewContext.save()

        let page = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 0..<0,
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(page.totalCount, 2)
        XCTAssertTrue(page.messageIDs.isEmpty)
    }

    func testInitialLoad_publishesOnlyViewContextMessages() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs && !state.isLoadingMore
        }

        XCTAssertEqual(state.totalMessageCount, 8)
        XCTAssertEqual(state.visibleMessages.map(\.id), Array(messages.prefix(4)).map(\.id))
    }

    func testInitialLoadFromEnd_publishesNewestMessagesOnViewContext() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs && !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleRangeStartIndex, 4)
        XCTAssertEqual(state.absoluteIndex(forVisibleIndex: 0), 4)
        XCTAssertEqual(state.absoluteIndex(forVisibleIndex: 3), 7)
        XCTAssertEqual(state.scrollPosition, 4)
        XCTAssertEqual(state.visibleMessages.map(\.id), Array(messages.suffix(4)).map(\.id))
    }

    func testInitialLoadFromEnd_includesPendingOptimisticMessageFromViewContext() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-pending",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 9 &&
                !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleRangeStartIndex, 5)
        XCTAssertEqual(state.scrollPosition, 5)
    }

    func testInitialLoadFromEnd_omitsExcludedPendingMessageWhileKeepingValidPendingMessage() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 3)
        let excludedLabels = makeExcludedLabels()
        try viewContext.save()
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 10,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let draftPendingMessage = try makePendingMessage(
            id: "virtual-scroll-pending-draft",
            date: Date(timeIntervalSince1970: 3),
            conversation: conversation
        )
        draftPendingMessage.addToLabels(excludedLabels.draft)
        let validPendingMessage = try makePendingMessage(
            id: "virtual-scroll-pending-valid",
            date: Date(timeIntervalSince1970: 4),
            conversation: conversation
        )

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedIDs = messages.map(\.objectID) + [validPendingMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 4 &&
                !state.isLoadingMore
        }
    }

    func testVisibleRowsRefreshWhenSenderPersonDisplayNameChanges() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let sender = PersonBuilder()
            .withEmail("info@bonbonwhims.com")
            .withDisplayName("Info")
            .build(in: viewContext)
        let message = MessageBuilder()
            .withId("virtual-scroll-person-refresh")
            .withSender(email: sender.email, name: nil)
            .withDate(Date(timeIntervalSince1970: 1))
            .inConversation(conversation)
            .build(in: viewContext)
        addMessageParticipant(person: sender, kind: .from, to: message)
        try viewContext.save()

        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: VirtualScrollConfiguration(
                visibleItemCount: 4,
                bufferSize: 1,
                pageSize: 3,
                preloadThreshold: 1
            ),
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.first?.senderInfoDisplayName == "Info"
        }

        sender.displayName = "BONBONWHIMS"
        viewContext.processPendingChanges()

        await waitUntil {
            state.visibleMessages.first?.senderInfoDisplayName == "BONBONWHIMS"
        }
    }

    func testInitialLoadFromEnd_doesNotLoadOlderWindowWhenTopOfTailFirstAppears() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let requestedRanges = RangeRecorder()

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await requestedRanges.record(range)
            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs && !state.isLoadingMore
        }

        let initialRanges = await requestedRanges.snapshot()
        state.markIndexVisible(4)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let rangesAfterMarkVisible = await requestedRanges.snapshot()
        XCTAssertEqual(rangesAfterMarkVisible, initialRanges)
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedIDs)
    }

    func testRapidOverlappingWindowLoads_keepPublishedMessagesOnViewContext() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 24)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 4,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let delayedLoader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            if range.lowerBound > 0 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled {
                    return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
                }
            }

            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: delayedLoader
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        state.markIndexVisible(8)
        state.markIndexVisible(14)

        let expectedFinalWindowIDs = Array(messages[13..<19]).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedFinalWindowIDs && !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleMessages.map(\.id), Array(messages[13..<19]).map(\.id))
    }

    func testLoadLatestWindowIfNeeded_refreshesForPendingOptimisticMessage() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.suffix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-pending-latest",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )

        await state.loadLatestWindowIfNeeded()

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 9 &&
                !state.isLoadingMore
        }
    }

    func testLoadLatestWindowIfNeeded_refreshesWhenKnownTotalCountIsAhead() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.suffix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        let newMessage = makeMessage(
            id: "virtual-scroll-persisted-latest",
            date: 8,
            conversation: conversation
        )
        try viewContext.save()

        await state.loadLatestWindowIfNeeded(knownTotalCount: 9)

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID) + [newMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 9 &&
                !state.isLoadingMore
        }
    }

    func testVisibleMessages_refreshWhenVisibleMessageReadStateChanges() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let message = MessageBuilder()
            .withId("virtual-scroll-read-state")
            .withSubject("Unread message")
            .withDate(Date(timeIntervalSince1970: 1))
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)

        try viewContext.save()

        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: VirtualScrollConfiguration(
                visibleItemCount: 1,
                bufferSize: 0,
                pageSize: 1,
                preloadThreshold: 1
            ),
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.count == 1 &&
                state.visibleMessages.first?.objectID == message.objectID &&
                state.visibleMessages.first?.isUnread == true &&
                !state.isLoadingMore
        }

        message.isUnread = false
        try viewContext.save()

        await waitUntil {
            state.visibleMessages.first?.isUnread == false
        }
    }

    func testVisibleMessages_refreshWhenVisibleAttachmentStateChanges() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let message = MessageBuilder()
            .withId("virtual-scroll-attachment-state")
            .withSubject("Attachment message")
            .withDate(Date(timeIntervalSince1970: 1))
            .withAttachments()
            .inConversation(conversation)
            .build(in: viewContext)
        let attachment = AttachmentBuilder()
            .withId("virtual-scroll-attachment")
            .asPDF()
            .queued()
            .forMessage(message)
            .build(in: viewContext)

        try viewContext.save()

        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: VirtualScrollConfiguration(
                visibleItemCount: 1,
                bufferSize: 0,
                pageSize: 1,
                preloadThreshold: 1
            ),
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.count == 1 &&
                state.visibleMessages.first?.objectID == message.objectID &&
                state.visibleMessages.first?.attachments.first?.stateRaw == Attachment.State.queued.rawValue &&
                !state.isLoadingMore
        }

        attachment.stateRaw = Attachment.State.downloaded.rawValue
        attachment.localURL = "Attachments/virtual-scroll-attachment.pdf"
        try viewContext.save()

        await waitUntil {
            state.visibleMessages.first?.attachments.first?.stateRaw == Attachment.State.downloaded.rawValue &&
                state.visibleMessages.first?.attachments.first?.localURL == "Attachments/virtual-scroll-attachment.pdf"
        }
    }

    func testReloadedWindow_keepsPendingOptimisticMessageVisible() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 3,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-pending-reload",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.suffix(3)).map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        state.markIndexVisible(2)

        let expectedIDs = messages.map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 9 &&
                !state.isLoadingMore
        }
    }

    func testPreloadPrevious_preservesPendingOptimisticMessageCount() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 0,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-pending-preload-previous",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages[6...7]).map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs &&
                state.totalMessageCount == 9 &&
                !state.isLoadingMore
        }

        state.scrollPosition = 9
        state.markIndexVisible(6)

        let expectedIDs = Array(messages[3...7]).map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 9 &&
                !state.isLoadingMore
        }
    }

    private func makeConversationWithMessages(count: Int) throws -> (Conversation, [Message]) {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)

        var messages: [Message] = []
        for index in 0..<count {
            let message = makeMessage(
                id: "virtual-scroll-\(index)",
                date: TimeInterval(index),
                conversation: conversation
            )
            messages.append(message)
        }

        try viewContext.save()
        return (conversation, messages)
    }

    private func makeMessage(
        id: String,
        date: TimeInterval,
        conversation: Conversation
    ) -> Message {
        MessageBuilder()
            .withId(id)
            .withSubject(id)
            .withDate(Date(timeIntervalSince1970: date))
            .inConversation(conversation)
            .build(in: viewContext)
    }

    private func makeExcludedLabels() -> (draft: Label, spam: Label, trash: Label) {
        (
            draft: LabelBuilder().draft().build(in: viewContext),
            spam: LabelBuilder().spam().build(in: viewContext),
            trash: LabelBuilder().trash().build(in: viewContext)
        )
    }

    private func makePendingMessage(
        id: String,
        date: Date,
        conversation: Conversation
    ) throws -> Message {
        let message = MessageBuilder()
            .withId(id)
            .withSubject(id)
            .withDate(date)
            .inConversation(conversation)
            .build(in: viewContext)

        try viewContext.obtainPermanentIDs(for: [message])
        viewContext.processPendingChanges()
        return message
    }

    private func addMessageParticipant(person: Person, kind: ParticipantKind, to message: Message) {
        let participant = MessageParticipant(context: viewContext)
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor RangeRecorder {
    private var ranges: [Range<Int>] = []

    func record(_ range: Range<Int>) {
        ranges.append(range)
    }

    func snapshot() -> [Range<Int>] {
        ranges
    }
}
