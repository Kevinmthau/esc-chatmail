import XCTest
import CoreData
import Combine
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

    func testInitialLoadCompletionStartsFalseAndPublishesAfterVisibleWindow() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 6)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let delayedLoader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            try? await Task.sleep(nanoseconds: 100_000_000)
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

        XCTAssertFalse(state.isInitialLoadComplete)

        let expectedIDs = Array(messages.prefix(3)).map(\.objectID)
        await waitUntil {
            state.isInitialLoadComplete &&
                state.visibleMessages.map(\.objectID) == expectedIDs &&
                !state.isLoadingMore
        }

        XCTAssertEqual(state.totalMessageCount, 6)
        XCTAssertEqual(state.visibleMessages.map(\.id), Array(messages.prefix(3)).map(\.id))
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
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.isInitialLoadComplete &&
                !state.isLoadingMore
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
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.isInitialLoadComplete &&
                !state.isLoadingMore
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

    func testInitialLoadFromEnd_includesPendingMessageInsertedDuringBackgroundLoad() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let requestedRanges = RangeRecorder()
        let firstRequestPause = FirstRequestPause()

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await requestedRanges.record(range)
            await firstRequestPause.waitIfNeeded()
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

        await waitUntilRecordedRangeCount(1, in: requestedRanges)

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-pending-during-initial-load",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )
        await firstRequestPause.release()

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

    func testRowForGroupingFetchesNextRowOutsideVisibleWindow() async throws {
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

        let initialIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        XCTAssertNil(state.row(atAbsoluteIndex: 4))
        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 4)?.objectID, messages[4].objectID)
    }

    func testRowForGroupingInvalidatesCachedBoundaryRowOutsideVisibleWindow() async throws {
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

        let initialIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 4)?.senderEmail, "sender@example.com")

        var visibleMessagesPublishCount = 0
        let cancellable = state.$visibleMessages.dropFirst().sink { _ in
            visibleMessagesPublishCount += 1
        }
        defer { cancellable.cancel() }

        messages[4].senderEmail = "boundary@example.com"
        try viewContext.save()

        await waitUntil {
            visibleMessagesPublishCount > 0 &&
                state.visibleMessages.map(\.objectID) == initialIDs &&
                state.rowForGrouping(atAbsoluteIndex: 4)?.senderEmail == "boundary@example.com"
        }
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

    func testInsertedPendingOptimisticMessageRefreshesLatestWindowWithoutScroll() async throws {
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
            id: "virtual-scroll-inserted-pending-latest",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            state.insertedVisibleMessageIDs == [pendingMessage.objectID] &&
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 9 &&
                !state.isLoadingMore
        }
    }

    func testInsertedMessageEventPublishesExactIDWhenAggregateCountIsUnchanged() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.isInitialLoadComplete && state.totalMessageCount == 4
        }

        let insertedMessage = MessageBuilder()
            .withId("inserted-with-deletion")
            .withDate(Date(timeIntervalSince1970: 4))
            .inConversation(conversation)
            .build(in: viewContext)
        try viewContext.obtainPermanentIDs(for: [insertedMessage])
        viewContext.delete(messages[0])
        viewContext.processPendingChanges()

        await waitUntil {
            state.insertedVisibleMessageIDs == [insertedMessage.objectID]
        }
    }

    func testInsertedPendingMessageRefreshesEmptyLatestWindow() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        try viewContext.save()
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

        await waitUntil {
            state.isInitialLoadComplete &&
                state.visibleMessages.isEmpty &&
                state.totalMessageCount == 0 &&
                !state.isLoadingMore
        }

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-empty-inserted-pending",
            date: Date(timeIntervalSince1970: 1),
            conversation: conversation
        )

        await waitUntil {
            state.visibleMessages.map(\.objectID) == [pendingMessage.objectID] &&
                state.totalMessageCount == 1 &&
                !state.isLoadingMore
        }
    }

    func testInsertedExcludedPendingMessageDoesNotChangeLatestWindow() async throws {
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

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let initialIDs = messages.map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        let draftMessage = MessageBuilder()
            .withId("virtual-scroll-inserted-draft-pending")
            .withSubject("virtual-scroll-inserted-draft-pending")
            .withDate(Date(timeIntervalSince1970: 3))
            .inConversation(conversation)
            .build(in: viewContext)
        draftMessage.addToLabels(excludedLabels.draft)
        try viewContext.obtainPermanentIDs(for: [draftMessage])
        viewContext.processPendingChanges()

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(state.insertedVisibleMessageIDs.isEmpty)
        XCTAssertEqual(state.visibleMessages.map(\.objectID), initialIDs)
        XCTAssertEqual(state.totalMessageCount, 3)
    }

    func testInsertedPendingMessageUpdatesCountWhenWindowIsNotLatest() async throws {
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

        let initialIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs &&
                state.totalMessageCount == 8 &&
                !state.isLoadingMore
        }

        _ = try makePendingMessage(
            id: "virtual-scroll-inserted-pending-away-from-latest",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )

        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs &&
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

    // MARK: - Window cap

    func testConfigurationDefaultsAndClampForMaxWindowSize() {
        XCTAssertEqual(VirtualScrollConfiguration.default.maxWindowSize, 300, "default is max(200, pageSize·6)")

        let clamped = VirtualScrollConfiguration(
            visibleItemCount: 20,
            bufferSize: 10,
            pageSize: 50,
            preloadThreshold: 5,
            maxWindowSize: 10
        )
        // visible + 2·buffer + 2·page = 140: smaller caps cause
        // window-replace/preload ping-pong.
        XCTAssertEqual(clamped.maxWindowSize, 140)

        let small = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1,
            maxWindowSize: 12
        )
        XCTAssertEqual(small.maxWindowSize, 12, "requests at or above the viable minimum are honored")
    }

    func testMessageWindowBackTrim_capsAndPreservesRangeInvariant() throws {
        let (_, messages) = try makeConversationWithMessages(count: 15)
        let ids = messages.map(\.objectID)

        // Window extended upward past the cap: rows 3..<15 prepended with 0..<3.
        let window = MessageWindow(
            startIndex: 0,
            endIndex: 15,
            messageIDs: ids,
            isLoading: false
        )

        let trimmed = window.backTrimmed(to: 12)

        XCTAssertEqual(trimmed.startIndex, 0)
        XCTAssertEqual(trimmed.endIndex, 12)
        XCTAssertEqual(trimmed.messageIDs, Array(ids.prefix(12)), "back-trim drops the largest absolute indices")
        XCTAssertEqual(trimmed.endIndex - trimmed.startIndex, trimmed.messageIDs.count, "grouping/boundary math depends on this invariant")

        // Under the cap: untouched.
        let untouched = trimmed.backTrimmed(to: 12)
        XCTAssertEqual(untouched.messageIDs.count, 12)
        XCTAssertEqual(untouched.endIndex, 12)
    }

    func testMessageWindowFrontTrim_capsAndPreservesRangeInvariant() throws {
        let (_, messages) = try makeConversationWithMessages(count: 15)
        let ids = messages.map(\.objectID)

        // Window extended downward past the cap: rows 0..<12 appended with 12..<15.
        let window = MessageWindow(
            startIndex: 0,
            endIndex: 15,
            messageIDs: ids,
            isLoading: false
        )

        let trimmed = window.frontTrimmed(to: 12)

        XCTAssertEqual(trimmed.startIndex, 3)
        XCTAssertEqual(trimmed.endIndex, 15)
        XCTAssertEqual(trimmed.messageIDs, Array(ids.suffix(12)), "front-trim drops the smallest absolute indices")
        XCTAssertEqual(trimmed.endIndex - trimmed.startIndex, trimmed.messageIDs.count, "grouping/boundary math depends on this invariant")
    }

    func testUpwardScrollSweep_neverExceedsWindowCapAndRecovers() async throws {
        // Property-style sweep: whatever mix of window replacements and
        // preloads the scheduler produces, the published window never exceeds
        // the cap and index math stays consistent; afterwards the latest
        // window is recoverable. Deliberately tolerant of interleaving —
        // the deterministic trim arithmetic is pinned by the MessageWindow
        // unit test above.
        let (conversation, messages) = try makeConversationWithMessages(count: 40)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1,
            maxWindowSize: 12
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

        // Walk upward through the conversation in production-like steps.
        var position = 36
        while position >= 0 {
            state.markIndexVisible(position)
            try? await Task.sleep(nanoseconds: 40_000_000)

            XCTAssertLessThanOrEqual(
                state.visibleMessages.count,
                configuration.maxWindowSize,
                "window rows exceeded the cap at position \(position)"
            )
            if !state.visibleMessages.isEmpty {
                XCTAssertEqual(
                    state.absoluteIndex(forVisibleIndex: 0),
                    state.visibleRangeStartIndex,
                    "index math out of sync at position \(position)"
                )
                let lastVisible = state.visibleMessages.count - 1
                XCTAssertEqual(
                    state.absoluteIndex(forVisibleIndex: lastVisible),
                    state.visibleRangeStartIndex + lastVisible
                )
            }

            position -= 3
        }

        // Recovery: the latest window is reachable again after scrolling up.
        await state.loadLatestWindowIfNeeded()
        await waitUntil {
            state.isShowingLatestWindow &&
                state.visibleMessages.last?.objectID == messages.last?.objectID
        }
    }

    func testDownwardPreloadAfterBackTrim_neverExceedsWindowCap() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 40)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 1,
            bufferSize: 0,
            pageSize: 3,
            preloadThreshold: 2,
            maxWindowSize: 7
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

        await waitUntil {
            state.visibleMessages.map(\.objectID) == [messages[39].objectID] && !state.isLoadingMore
        }

        state.scrollPosition = 42
        state.markIndexVisible(39)
        await waitUntil {
            state.visibleRangeStartIndex == 36 &&
                state.visibleMessages.map(\.objectID) == Array(messages[36..<40]).map(\.objectID)
        }

        state.scrollPosition = 39
        state.markIndexVisible(36)
        await waitUntil {
            state.visibleRangeStartIndex == 33 &&
                state.visibleMessages.map(\.objectID) == Array(messages[33..<40]).map(\.objectID)
        }

        state.scrollPosition = 36
        state.markIndexVisible(33)
        await waitUntil {
            state.visibleRangeStartIndex == 30 &&
                state.visibleMessages.map(\.objectID) == Array(messages[30..<37]).map(\.objectID)
        }

        state.scrollPosition = 33
        state.markIndexVisible(36)
        await waitUntil {
            state.visibleRangeStartIndex == 33 &&
                state.visibleMessages.map(\.objectID) == Array(messages[33..<40]).map(\.objectID)
        }

        XCTAssertLessThanOrEqual(state.visibleMessages.count, configuration.maxWindowSize)
        XCTAssertEqual(state.visibleMessages.last?.objectID, messages.last?.objectID)
    }

    // MARK: - objectsDidChange relevance guard

    func testRelevanceGuard_conversationOnlyChanges_areIrrelevant() throws {
        let conversation = ConversationBuilder().visible().build(in: viewContext)
        try viewContext.save()

        let userInfo: [AnyHashable: Any] = [NSUpdatedObjectsKey: Set<NSManagedObject>([conversation])]
        XCTAssertFalse(VirtualScrollState.isRelevantChatContextChange(userInfo))
    }

    func testRelevanceGuard_messageAndAttachmentChanges_areRelevant() throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 1)
        _ = conversation
        let message = messages[0]
        let attachment = AttachmentBuilder().forMessage(message).build(in: viewContext)
        try viewContext.save()

        XCTAssertTrue(VirtualScrollState.isRelevantChatContextChange(
            [NSInsertedObjectsKey: Set<NSManagedObject>([message])]
        ))
        XCTAssertTrue(VirtualScrollState.isRelevantChatContextChange(
            [NSUpdatedObjectsKey: Set<NSManagedObject>([attachment])]
        ))
    }

    func testRelevanceGuard_personChanges_relevantOnlyWhenUpdatedOrRefreshed() throws {
        let person = PersonBuilder().build(in: viewContext)
        try viewContext.save()

        XCTAssertTrue(VirtualScrollState.isRelevantChatContextChange(
            [NSRefreshedObjectsKey: Set<NSManagedObject>([person])]
        ))
        XCTAssertFalse(VirtualScrollState.isRelevantChatContextChange(
            [NSInsertedObjectsKey: Set<NSManagedObject>([person])]
        ))
        XCTAssertFalse(VirtualScrollState.isRelevantChatContextChange(nil))
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
        let participant = viewContext.insertTestObject(MessageParticipant.self)
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

    private func waitUntilRecordedRangeCount(
        _ expectedCount: Int,
        in recorder: RangeRecorder,
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await recorder.snapshot().count >= expectedCount {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for recorded range count", file: file, line: line)
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

private actor FirstRequestPause {
    private var shouldPauseNextRequest = true
    private var isReleased = false

    func waitIfNeeded() async {
        guard shouldPauseNextRequest else { return }
        shouldPauseNextRequest = false

        while !isReleased && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func release() {
        isReleased = true
    }
}
