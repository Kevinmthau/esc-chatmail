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

    func testLoadMessagePage_equalTimestampsUseStableIDOrderingAcrossPages() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let messageIDs = ["message-d", "message-b", "message-a", "message-c"]
        var messages: [Message] = []

        for messageID in messageIDs {
            let message = makeMessage(
                id: messageID,
                date: 1,
                conversation: conversation
            )
            messages.append(message)
        }
        try viewContext.save()
        let objectIDByMessageID = Dictionary(
            uniqueKeysWithValues: messages.map { ($0.id, $0.objectID) }
        )

        let firstPage = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 0..<2,
            in: stack.newBackgroundContext()
        )
        let secondPage = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 2..<4,
            in: stack.newBackgroundContext()
        )
        let expectedIDs = ["message-a", "message-b", "message-c", "message-d"]
            .compactMap { objectIDByMessageID[$0] }

        XCTAssertEqual(firstPage.messageIDs + secondPage.messageIDs, expectedIDs)
        XCTAssertEqual(
            Set(firstPage.messageIDs).intersection(secondPage.messageIDs),
            []
        )
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
        XCTAssertEqual(state.initialLoadPhase, .loaded)
        XCTAssertNil(state.initialLoadFailureReason)
    }

    func testInitialLoadFromBeginning_publishesOldestMessagesChronologically() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 25)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 8,
            bufferSize: 2,
            pageSize: 8,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedMessages = Array(messages.prefix(8))
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == expectedMessages.map(\.objectID) &&
                !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleRangeStartIndex, 0)
        XCTAssertEqual(state.totalMessageCount, messages.count)
        XCTAssertEqual(
            state.visibleMessages.map(\.id),
            expectedMessages.map(\.id)
        )
        XCTAssertFalse(state.isShowingLatestWindow)
    }

    func testTailInsertionPreservesBeginningWindowWhenLatestFollowingIsDisabled() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 8,
            bufferSize: 2,
            pageSize: 8,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        state.setFollowsLatestInsertions(false)
        defer { state.cleanup() }

        let initialMessageIDs = messages.map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == initialMessageIDs &&
                !state.isLoadingMore
        }
        XCTAssertTrue(state.isShowingLatestWindow)

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-top-presented-tail-insert",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )

        await waitUntil {
            state.totalMessageCount == 9 &&
                state.visibleMessages.map(\.objectID) == initialMessageIDs &&
                !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleRangeStartIndex, 0)
        XCTAssertFalse(state.isShowingLatestWindow)

        state.setFollowsLatestInsertions(true)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialMessageIDs + [pendingMessage.objectID] &&
                state.isShowingLatestWindow &&
                !state.isLoadingMore
        }
    }

    func testResumeRestartsAnInterruptedInitialLoad() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 3)
        let stack = self.stack!
        var loadCount = 0
        let delayedLoader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            loadCount += 1
            if loadCount == 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: delayedLoader
        )
        defer { state.cleanup() }

        await waitUntil {
            loadCount == 1 && state.initialLoadPhase == .loading
        }
        state.cleanup()
        state.resume()

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }
        XCTAssertGreaterThanOrEqual(loadCount, 2)
    }

    func testResumeReconcilesMessagesInsertedWhileAnEmptyStateWasInactive() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        try viewContext.save()
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .empty
        }
        state.cleanup()

        let message = makeMessage(
            id: "virtual-scroll-inactive-insert",
            date: 1,
            conversation: conversation
        )
        try viewContext.save()

        state.resume()
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == [message.objectID]
        }
    }

    func testResumePreservesAnOlderWindowWhileReconcilingItsRows() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedVisibleIDs = Array(messages.prefix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == expectedVisibleIDs
        }
        XCTAssertFalse(state.isShowingLatestWindow)
        state.cleanup()

        _ = makeMessage(
            id: "virtual-scroll-inactive-tail-insert",
            date: 100,
            conversation: conversation
        )
        try viewContext.save()

        state.resume()
        await waitUntil {
            state.totalMessageCount == 9 && !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedVisibleIDs)
        XCTAssertFalse(state.isShowingLatestWindow)
        XCTAssertEqual(state.scrollPosition, 0)
    }

    func testResumeLatestWindowDoesNotPublishAfterFollowingIsDisabled() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 4,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 3)
        let stack = self.stack!
        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await pause.waitIfNeeded()
            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let initialMessageIDs = messages.map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == initialMessageIDs
        }
        state.cleanup()

        _ = makeMessage(
            id: "virtual-scroll-inactive-follow-intent-tail",
            date: 10,
            conversation: conversation
        )
        try viewContext.save()

        state.resume()
        await pause.waitUntilPaused()
        state.setFollowsLatestInsertions(false)
        await pause.release()

        await waitUntil {
            state.totalMessageCount == 5 &&
                state.visibleMessages.map(\.objectID) == initialMessageIDs &&
                !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleRangeStartIndex, 0)
        XCTAssertFalse(state.isShowingLatestWindow)
    }

    func testExplicitLatestWindowLoadPublishesAfterFollowingIsDisabled() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 4,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 3)
        let stack = self.stack!
        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await pause.waitIfNeeded()
            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }
        state.cleanup()

        let pendingMessage = makeMessage(
            id: "virtual-scroll-explicit-latest-tail",
            date: 10,
            conversation: conversation
        )
        try viewContext.save()

        let latestLoad = Task {
            await state.loadLatestWindow()
        }
        await pause.waitUntilPaused()
        state.setFollowsLatestInsertions(false)
        await pause.release()

        let didLoadLatest = await latestLoad.value
        XCTAssertTrue(didLoadLatest)
        XCTAssertEqual(
            state.visibleMessages.map(\.objectID),
            Array(messages.dropFirst()).map(\.objectID) + [pendingMessage.objectID]
        )
        XCTAssertEqual(state.totalMessageCount, 5)
        XCTAssertEqual(state.visibleRangeStartIndex, 1)
        XCTAssertTrue(state.isShowingLatestWindow)
    }

    func testEnsureVisibleMessagePublishesPendingTargetWhenFollowingIsDisabled() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 4,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let initialMessageIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == initialMessageIDs
        }
        state.setFollowsLatestInsertions(false)

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-ensure-visible-pending",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )
        await waitUntil {
            state.totalMessageCount == 9 &&
                state.visibleMessages.map(\.objectID) == initialMessageIDs
        }

        let didEnsureTarget = await state.ensureVisibleMessage(
            pendingMessage.objectID
        )

        XCTAssertTrue(didEnsureTarget)
        XCTAssertEqual(
            state.visibleMessages.map(\.objectID),
            Array(messages.suffix(3)).map(\.objectID) + [pendingMessage.objectID]
        )
        XCTAssertEqual(state.totalMessageCount, 9)
        XCTAssertTrue(state.isShowingLatestWindow)
    }

    func testEnsureVisibleMessageAlreadyPublishedDoesNotReloadWindow() async throws {
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
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        var publishCount = 0
        let cancellable = state.$visibleMessages.dropFirst().sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let didEnsureTarget = await state.ensureVisibleMessage(
            messages.last!.objectID
        )

        XCTAssertTrue(didEnsureTarget)
        XCTAssertEqual(publishCount, 0)
    }

    func testEnsureVisibleMessageStopsAfterSingleRetryWhenTargetIsAbsent() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let unrelatedConversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let unrelatedMessage = makeMessage(
            id: "virtual-scroll-unrelated-ensure-target",
            date: 10,
            conversation: unrelatedConversation
        )
        try viewContext.save()

        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        var publishCount = 0
        let cancellable = state.$visibleMessages.dropFirst().sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let didEnsureTarget = await state.ensureVisibleMessage(
            unrelatedMessage.objectID
        )

        XCTAssertFalse(didEnsureTarget)
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(
            state.visibleMessages.map(\.objectID),
            messages.map(\.objectID)
        )
    }

    func testResumeClampsHistoricalWindowAfterLargeInactiveDeletion() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 12)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) ==
                Array(messages.prefix(3)).map(\.objectID)
        }
        state.markIndexVisible(6)
        let historicalIDs = Array(messages[5..<10]).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == historicalIDs &&
                !state.isShowingLatestWindow &&
                !state.isLoadingMore
        }
        state.cleanup()

        for message in messages.prefix(10) {
            viewContext.delete(message)
        }
        try viewContext.save()

        state.resume()
        let remainingIDs = Array(messages.suffix(2)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == remainingIDs &&
                state.totalMessageCount == 2 &&
                !state.isLoadingMore
        }
        XCTAssertTrue(state.isShowingLatestWindow)
        XCTAssertEqual(state.visibleRangeStartIndex, 0)
    }

    func testInitialLoadEmptyConversationPublishesEmptyPhase() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        try viewContext.save()
        let stack = self.stack!

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .empty && !state.isLoadingMore
        }

        XCTAssertTrue(state.isInitialLoadComplete)
        XCTAssertTrue(state.visibleMessages.isEmpty)
        XCTAssertEqual(state.totalMessageCount, 0)
        XCTAssertNil(state.initialLoadFailureReason)
    }

    func testEmptyResumeFailurePublishesRetryableFailureAndManualRetryRecovers() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        try viewContext.save()
        let attempts = InitialLoadAttemptCounter()
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let attempt = await attempts.next()
            if attempt == 4 {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 1,
                    fetchErrorDescription: "Injected empty-resume failure"
                )
            }
            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .empty
        }
        state.cleanup()
        let message = makeMessage(
            id: "virtual-scroll-empty-resume-retry",
            date: 1,
            conversation: conversation
        )
        try viewContext.save()

        state.resume()
        await waitUntil {
            state.initialLoadPhase == .failed &&
                state.visibleMessages.isEmpty &&
                !state.isLoadingMore
        }
        XCTAssertFalse(state.isInitialLoadComplete)
        XCTAssertNotNil(state.initialLoadFailureReason)

        state.retryInitialLoad()
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == [message.objectID]
        }
        XCTAssertNil(state.initialLoadFailureReason)
    }

    func testInitialLoadNonzeroTotalWithoutResolvableRowsAutomaticallyRetriesAndRecovers() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 2)
        let attempts = InitialLoadAttemptCounter()
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let attempt = await attempts.next()
            if attempt == 1 {
                return VirtualScrollMessagePage(messageIDs: [], totalCount: 2)
            }

            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        let attemptCount = await attempts.snapshot()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertNil(state.initialLoadFailureReason)
    }

    func testInitialLoadNonzeroTotalWithoutResolvableRowsFailsAfterBoundedRetryAndManualRetryRecovers() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 2)
        let attempts = InitialLoadAttemptCounter()
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let attempt = await attempts.next()
            if attempt <= 2 {
                return VirtualScrollMessagePage(messageIDs: [], totalCount: 2)
            }

            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .failed
        }

        var attemptCount = await attempts.snapshot()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(state.totalMessageCount, 2)
        XCTAssertFalse(state.isInitialLoadComplete)
        XCTAssertNotNil(state.initialLoadFailureReason)
        XCTAssertFalse(state.isLoadingMore)

        state.retryInitialLoad()
        XCTAssertEqual(state.initialLoadPhase, .loading)
        XCTAssertFalse(state.isInitialLoadComplete)
        XCTAssertNil(state.initialLoadFailureReason)

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        attemptCount = await attempts.snapshot()
        XCTAssertEqual(attemptCount, 3)
        XCTAssertNil(state.initialLoadFailureReason)
    }

    func testInitialLoadFetchErrorFailsAfterBoundedRetryAndManualRetryRecoversFromZeroCount() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 2)
        let attempts = InitialLoadAttemptCounter()
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let attempt = await attempts.next()
            if attempt <= 2 {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 0,
                    fetchErrorDescription: "Injected fetch failure"
                )
            }

            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .failed
        }

        var attemptCount = await attempts.snapshot()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(state.totalMessageCount, 0)
        XCTAssertFalse(state.isInitialLoadComplete)
        XCTAssertNotNil(state.initialLoadFailureReason)

        state.retryInitialLoad()
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        attemptCount = await attempts.snapshot()
        XCTAssertEqual(attemptCount, 3)
        XCTAssertEqual(state.totalMessageCount, 2)
        XCTAssertNil(state.initialLoadFailureReason)
    }

    func testLatestWindowFetchFailuresPreserveLoadedRows() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 5)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let attempts = InitialLoadAttemptCounter()
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let attempt = await attempts.next()
            if attempt == 3 || attempt == 5 {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 0,
                    fetchErrorDescription: "Injected later fetch failure"
                )
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
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == expectedIDs
        }

        await state.loadLatestWindow()
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedIDs)
        XCTAssertEqual(state.totalMessageCount, 5)
        XCTAssertEqual(state.initialLoadPhase, .loaded)
        XCTAssertFalse(state.isLoadingMore)

        await state.loadLatestWindow()
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedIDs)
        XCTAssertEqual(state.totalMessageCount, 5)
        XCTAssertEqual(state.initialLoadPhase, .loaded)
        XCTAssertFalse(state.isLoadingMore)
    }

    func testLatestWindowCountDriftRebasesBeforePublishing() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 5)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let attempts = InitialLoadAttemptCounter()
        let ranges = RangeRecorder()
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await ranges.record(range)
            let attempt = await attempts.next()
            if attempt == 3 {
                return VirtualScrollMessagePage(messageIDs: [], totalCount: 100)
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
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == expectedIDs
        }

        await state.loadLatestWindow()

        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedIDs)
        XCTAssertEqual(state.totalMessageCount, 5)
        XCTAssertEqual(state.scrollPosition, 4)
        let recordedRanges = await ranges.snapshot()
        XCTAssertEqual(
            recordedRanges,
            [0..<0, 2..<5, 0..<0, 97..<100, 2..<5]
        )
    }

    func testOlderLatestRequestCannotOverwriteNewerPendingWindow() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 3)
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await pause.waitIfNeeded()
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

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        let olderRequest = Task {
            _ = await state.loadLatestWindow()
        }
        await pause.waitUntilPaused()

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-newer-pending-window",
            date: Date(timeIntervalSince1970: 10),
            conversation: conversation
        )
        await state.loadLatestWindow()
        await waitUntil {
            state.visibleMessages.last?.objectID == pendingMessage.objectID &&
                state.totalMessageCount == 5
        }

        await pause.release()
        await olderRequest.value

        XCTAssertEqual(state.visibleMessages.last?.objectID, pendingMessage.objectID)
        XCTAssertEqual(state.totalMessageCount, 5)
        XCTAssertEqual(state.initialLoadPhase, .loaded)
    }

    func testWindowLoadedBeforeMutationCannotOverwriteNewerDatasetState() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 10)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 3)
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
            await pause.waitIfNeeded()
            return page
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.prefix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == initialIDs
        }

        let staleLatestLoad = Task {
            _ = await state.loadLatestWindow()
        }
        await pause.waitUntilPaused()

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-mutation-during-window-load",
            date: Date(timeIntervalSince1970: 10),
            conversation: conversation
        )
        await waitUntil {
            state.totalMessageCount == 11
        }

        await pause.release()
        await staleLatestLoad.value

        let expectedLatestIDs =
            Array(messages.suffix(2)).map(\.objectID) + [pendingMessage.objectID]
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedLatestIDs)
        XCTAssertEqual(state.totalMessageCount, 11)
        XCTAssertEqual(state.initialLoadPhase, .loaded)
        XCTAssertTrue(state.isShowingLatestWindow)
        XCTAssertFalse(state.isLoadingMore)
        XCTAssertTrue(state.placeholderIndices.isEmpty)
    }

    func testBackgroundInsertionDuringLatestLoadCannotPublishStaleWindow() async throws {
        stack = TestCoreDataStack(automaticallyMergesChanges: true)
        viewContext = stack.viewContext
        let (conversation, messages) = try makeConversationWithMessages(count: 10)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 3)
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
            await pause.waitIfNeeded()
            return page
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.prefix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == initialIDs
        }

        var publishedWindows: [[NSManagedObjectID]] = []
        let publishedWindowsCancellable = state.$visibleMessages
            .dropFirst()
            .sink { publishedWindows.append($0.map(\.objectID)) }
        defer { publishedWindowsCancellable.cancel() }

        let staleLatestLoad = Task {
            _ = await state.loadLatestWindow()
        }
        await pause.waitUntilPaused()

        let conversationID = conversation.objectID
        let backgroundContext = stack.newBackgroundContext()
        let insertedMessageID = try await backgroundContext.perform {
            let backgroundConversation = try XCTUnwrap(
                backgroundContext.existingObject(with: conversationID) as? Conversation
            )
            let message = MessageBuilder()
                .withId("virtual-scroll-background-insertion")
                .withSubject("virtual-scroll-background-insertion")
                .withDate(Date(timeIntervalSince1970: 10))
                .inConversation(backgroundConversation)
                .build(in: backgroundContext)
            try backgroundContext.save()
            return message.objectID
        }

        await waitUntil {
            state.totalMessageCount == 11
        }

        await pause.release()
        await staleLatestLoad.value

        let expectedLatestIDs =
            Array(messages.suffix(2)).map(\.objectID) + [insertedMessageID]
        let staleLatestIDs = Array(messages.suffix(3)).map(\.objectID)
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedLatestIDs)
        XCTAssertFalse(publishedWindows.contains(staleLatestIDs))
        XCTAssertEqual(state.totalMessageCount, 11)
        XCTAssertTrue(state.isShowingLatestWindow)
        XCTAssertFalse(state.isLoadingMore)
    }

    func testLatestMetadataLoadedBeforeMutationCannotStartAStaleWindowLoad() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 10)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 2)
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
            await pause.waitIfNeeded()
            return page
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.prefix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == initialIDs
        }

        let staleLatestLoad = Task {
            _ = await state.loadLatestWindow()
        }
        await pause.waitUntilPaused()

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-mutation-during-latest-metadata",
            date: Date(timeIntervalSince1970: 10),
            conversation: conversation
        )
        await waitUntil {
            state.totalMessageCount == 11
        }

        await pause.release()
        await staleLatestLoad.value

        let expectedLatestIDs =
            Array(messages.suffix(2)).map(\.objectID) + [pendingMessage.objectID]
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedLatestIDs)
        XCTAssertEqual(state.totalMessageCount, 11)
        XCTAssertEqual(state.initialLoadPhase, .loaded)
        XCTAssertTrue(state.isShowingLatestWindow)
        XCTAssertFalse(state.isLoadingMore)
        XCTAssertTrue(state.placeholderIndices.isEmpty)
    }

    func testRepeatedDatasetChangesDuringLatestLoadEventuallyReconcile() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 10)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = RequestSequencePause(targetRequests: [3, 4])
        let stack = self.stack!
        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
            await pause.waitIfNeeded()
            return page
        }
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) ==
                Array(messages.prefix(3)).map(\.objectID)
        }

        let latestLoad = Task {
            _ = await state.loadLatestWindow()
        }
        await pause.waitUntilPaused(stage: 0)

        messages[0].internalDate = Date(timeIntervalSince1970: 20)
        try viewContext.save()
        await pause.release(stage: 0)
        await pause.waitUntilPaused(stage: 1)

        messages[1].internalDate = Date(timeIntervalSince1970: 21)
        try viewContext.save()
        await pause.release(stage: 1)
        await latestLoad.value

        let expectedIDs = [messages[9], messages[0], messages[1]].map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 10 &&
                state.isShowingLatestWindow &&
                !state.isLoadingMore
        }
    }

    func testCancellingCurrentLatestWindowLoadClearsLoadingState() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let pause = RequestNumberPause(targetRequest: 4)
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await pause.waitIfNeeded()
            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        let loadTask = Task {
            _ = await state.loadLatestWindow()
        }
        await pause.waitUntilPaused()
        XCTAssertTrue(state.isLoadingMore)

        loadTask.cancel()
        await pause.release()
        await loadTask.value

        XCTAssertFalse(state.isLoadingMore)
        XCTAssertTrue(state.placeholderIndices.isEmpty)
        XCTAssertEqual(state.visibleMessages.map(\.objectID), messages.map(\.objectID))
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

    func testInitialLoadFromEndRebasesWhenCountIncreasesBetweenMetadataAndPage() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 6)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let requestedRanges = RangeRecorder()
        let stack = self.stack!

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await requestedRanges.record(range)
            if range.isEmpty {
                return VirtualScrollMessagePage(messageIDs: [], totalCount: 5)
            }
            if range == 2..<5 {
                return VirtualScrollMessagePage(
                    messageIDs: Array(messages[2..<5]).map(\.objectID),
                    totalCount: 6
                )
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
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.isShowingLatestWindow
        }

        let ranges = await requestedRanges.snapshot()
        XCTAssertEqual(ranges, [0..<0, 2..<5, 3..<6])
        XCTAssertEqual(state.totalMessageCount, 6)
        XCTAssertEqual(state.visibleRangeStartIndex, 3)
    }

    func testInitialLoadFromEndRetriesAnEqualCountDatasetReplacement() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 6)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 2)
        let stack = self.stack!
        var publishedWindows: [[NSManagedObjectID]] = []
        var cancellable: AnyCancellable?

        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
            await pause.waitIfNeeded()
            return page
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer {
            cancellable?.cancel()
            state.cleanup()
        }
        cancellable = state.$visibleMessages
            .dropFirst()
            .sink { publishedWindows.append($0.map(\.objectID)) }

        await pause.waitUntilPaused()
        let replacement = try makePendingMessage(
            id: "virtual-scroll-equal-count-replacement",
            date: Date(timeIntervalSince1970: 6),
            conversation: conversation
        )
        viewContext.delete(messages[0])
        viewContext.processPendingChanges()
        try viewContext.save()
        XCTAssertEqual(replacement.conversation?.id, conversation.id)
        await pause.release()

        let expectedIDs = [messages[4].objectID, messages[5].objectID, replacement.objectID]
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 6
        }

        let staleIDs = Array(messages[3...5]).map(\.objectID)
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedIDs)
        XCTAssertEqual(state.totalMessageCount, 6)
        XCTAssertEqual(state.initialLoadPhase, .loaded)
        XCTAssertFalse(publishedWindows.contains(staleIDs))
        XCTAssertTrue(state.isShowingLatestWindow)
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

        var insertedEvents: [VirtualScrollInsertedMessageEvent] = []
        var refreshedEvents: [VirtualScrollInsertedMessageRefresh] = []
        let insertedEventsCancellable = state.insertedVisibleMessageEvents.sink {
            insertedEvents.append($0)
        }
        let refreshedEventsCancellable = state.refreshedInsertedMessageEvents.sink {
            refreshedEvents.append($0)
        }
        defer {
            insertedEventsCancellable.cancel()
            refreshedEventsCancellable.cancel()
        }

        let pendingMessage = try makePendingMessage(
            id: "virtual-scroll-inserted-pending-latest",
            date: Date(timeIntervalSince1970: 8),
            conversation: conversation
        )
        XCTAssertEqual(state.totalMessageCount, 9)
        XCTAssertTrue(
            state.isShowingLatestWindow,
            "A pending tail insertion must preserve sticky-latest intent before its window publishes"
        )

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID) + [pendingMessage.objectID]
        await waitUntil {
            insertedEvents.last?.messageIDs == [pendingMessage.objectID] &&
                refreshedEvents.last?.eventID == insertedEvents.last?.id &&
                refreshedEvents.last?.layoutID == state.latestWindowLayoutID &&
                refreshedEvents.last?.messageIDsInLatestWindow == [pendingMessage.objectID] &&
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

        var insertedEvents: [VirtualScrollInsertedMessageEvent] = []
        var refreshedEvents: [VirtualScrollInsertedMessageRefresh] = []
        var observedCounts: [Int] = []
        let insertedEventsCancellable = state.insertedVisibleMessageEvents.sink {
            insertedEvents.append($0)
        }
        let refreshedEventsCancellable = state.refreshedInsertedMessageEvents.sink {
            refreshedEvents.append($0)
        }
        let countCancellable = state.$totalMessageCount.sink {
            observedCounts.append($0)
        }
        defer {
            insertedEventsCancellable.cancel()
            refreshedEventsCancellable.cancel()
            countCancellable.cancel()
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
            insertedEvents.last?.messageIDs == [insertedMessage.objectID] &&
                refreshedEvents.last?.eventID == insertedEvents.last?.id &&
                refreshedEvents.last?.layoutID == state.latestWindowLayoutID &&
                refreshedEvents.last?.messageIDsInLatestWindow == [insertedMessage.objectID] &&
                state.totalMessageCount == 4
        }
        XCTAssertFalse(observedCounts.contains(5))
    }

    func testHistoricalInsertedMessageIsNotAnAutoReadCandidate() async throws {
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
            state.isInitialLoadComplete &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID) &&
                !state.isLoadingMore
        }

        var insertedEvents: [VirtualScrollInsertedMessageEvent] = []
        var refreshedEvents: [VirtualScrollInsertedMessageRefresh] = []
        let insertedEventsCancellable = state.insertedVisibleMessageEvents.sink {
            insertedEvents.append($0)
        }
        let refreshedEventsCancellable = state.refreshedInsertedMessageEvents.sink {
            refreshedEvents.append($0)
        }
        defer {
            insertedEventsCancellable.cancel()
            refreshedEventsCancellable.cancel()
        }

        let historicalMessage = try makePendingMessage(
            id: "historical-inserted-message",
            date: Date(timeIntervalSince1970: 0.5),
            conversation: conversation
        )

        await waitUntil {
            guard let event = insertedEvents.last,
                  event.messageIDs == [historicalMessage.objectID],
                  let refresh = refreshedEvents.last else {
                return false
            }
            return refresh.eventID == event.id && refresh.messageIDsInLatestWindow.isEmpty
        }
    }

    func testHistoricalInsertedMessageAfterTailDeletionIsNotAnAutoReadCandidate() async throws {
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
            state.isInitialLoadComplete &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID) &&
                !state.isLoadingMore
        }

        var insertedEvents: [VirtualScrollInsertedMessageEvent] = []
        var refreshedEvents: [VirtualScrollInsertedMessageRefresh] = []
        let insertedEventsCancellable = state.insertedVisibleMessageEvents.sink {
            insertedEvents.append($0)
        }
        let refreshedEventsCancellable = state.refreshedInsertedMessageEvents.sink {
            refreshedEvents.append($0)
        }
        defer {
            insertedEventsCancellable.cancel()
            refreshedEventsCancellable.cancel()
        }

        viewContext.delete(messages.last!)
        viewContext.processPendingChanges()

        let historicalMessage = try makePendingMessage(
            id: "historical-after-tail-deletion",
            date: Date(timeIntervalSince1970: 0.5),
            conversation: conversation
        )

        await waitUntil {
            guard let event = insertedEvents.last,
                  event.messageIDs == [historicalMessage.objectID],
                  let refresh = refreshedEvents.last else {
                return false
            }
            return refresh.eventID == event.id && refresh.messageIDsInLatestWindow.isEmpty
        }
    }

    func testRapidInsertedMessageEventsAreDeliveredAndRefreshedIndependently() async throws {
        let (conversation, _) = try makeConversationWithMessages(count: 2)
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.isInitialLoadComplete && state.totalMessageCount == 2
        }

        var insertedEvents: [VirtualScrollInsertedMessageEvent] = []
        var refreshedEvents: [VirtualScrollInsertedMessageRefresh] = []
        let insertedEventsCancellable = state.insertedVisibleMessageEvents.sink {
            insertedEvents.append($0)
        }
        let refreshedEventsCancellable = state.refreshedInsertedMessageEvents.sink {
            refreshedEvents.append($0)
        }
        defer {
            insertedEventsCancellable.cancel()
            refreshedEventsCancellable.cancel()
        }

        let firstMessage = try makePendingMessage(
            id: "first-rapid-insert",
            date: Date(timeIntervalSince1970: 2),
            conversation: conversation
        )
        let secondMessage = try makePendingMessage(
            id: "second-rapid-insert",
            date: Date(timeIntervalSince1970: 3),
            conversation: conversation
        )

        await waitUntil {
            insertedEvents.map(\.messageIDs) == [[firstMessage.objectID], [secondMessage.objectID]] &&
                refreshedEvents.count == 2
        }

        XCTAssertEqual(Set(refreshedEvents.map(\.eventID)), Set(insertedEvents.map(\.id)))
        XCTAssertEqual(Set(refreshedEvents.map(\.layoutID)), [state.latestWindowLayoutID])
        XCTAssertEqual(
            refreshedEvents.map(\.messageIDsInLatestWindow),
            [[firstMessage.objectID], [secondMessage.objectID]]
        )
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
                state.initialLoadPhase == .loaded &&
                !state.isLoadingMore
        }
    }

    func testDeletingLastVisibleMessagePublishesEmptyPhaseInsteadOfBlankLoadedState() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 1)
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        viewContext.delete(messages[0])
        viewContext.processPendingChanges()

        await waitUntil {
            state.initialLoadPhase == .empty &&
                state.visibleMessages.isEmpty &&
                state.totalMessageCount == 0 &&
                !state.isLoadingMore
        }
    }

    func testDeletingMessageOutsideCurrentWindowReconcilesTotalCount() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.prefix(3)).map(\.objectID)
        await waitUntil {
            state.initialLoadPhase == .loaded &&
                state.visibleMessages.map(\.objectID) == initialIDs
        }

        viewContext.delete(messages[7])
        viewContext.processPendingChanges()

        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs &&
                state.totalMessageCount == 7 &&
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

        var insertedEvents: [VirtualScrollInsertedMessageEvent] = []
        let insertedEventsCancellable = state.insertedVisibleMessageEvents.sink {
            insertedEvents.append($0)
        }
        defer { insertedEventsCancellable.cancel() }

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

        XCTAssertTrue(insertedEvents.isEmpty)
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

    func testInsertedMessageRebasesHistoricalWindowWhenItSortsInsideTheWindow() async throws {
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
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) ==
                Array(messages.prefix(4)).map(\.objectID)
        }

        let insertedMessage = try makePendingMessage(
            id: "virtual-scroll-inserted-inside-historical-window",
            date: Date(timeIntervalSince1970: 1.5),
            conversation: conversation
        )
        let expectedIDs = [
            messages[0].objectID,
            messages[1].objectID,
            insertedMessage.objectID,
            messages[2].objectID
        ]

        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 9 &&
                state.visibleRangeStartIndex == 0 &&
                !state.isLoadingMore
        }
    }

    func testAddingExcludedLabelRemovesMessageFromLatestWindow() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let excludedLabels = makeExcludedLabels()
        try viewContext.save()
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }

        messages[1].addToLabels(excludedLabels.draft)
        viewContext.processPendingChanges()

        let expectedIDs = [messages[0], messages[2], messages[3]].map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 3 &&
                state.initialLoadPhase == .loaded &&
                !state.isLoadingMore
        }
    }

    func testAddingNonexcludedLabelRefreshesRowsWithoutReloadingWindow() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 4)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        try viewContext.save()
        let requestedRanges = RangeRecorder()
        let stack = self.stack!
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
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) == messages.map(\.objectID)
        }
        let initialRequestCount = await requestedRanges.snapshot().count
        XCTAssertEqual(initialRequestCount, 1)

        messages[1].addToLabels(inboxLabel)
        viewContext.processPendingChanges()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(state.visibleMessages.map(\.objectID), messages.map(\.objectID))
        XCTAssertEqual(state.totalMessageCount, 4)
        let finalRequestCount = await requestedRanges.snapshot().count
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertFalse(state.isLoadingMore)
    }

    func testRemovingExcludedLabelRecoversEmptyConversationWithoutScroll() async throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let excludedLabels = makeExcludedLabels()
        let message = makeMessage(
            id: "virtual-scroll-draft-becomes-visible",
            date: 1,
            conversation: conversation
        )
        message.addToLabels(excludedLabels.draft)
        try viewContext.save()
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.initialLoadPhase == .empty &&
                state.visibleMessages.isEmpty &&
                state.totalMessageCount == 0
        }

        message.removeFromLabels(excludedLabels.draft)
        viewContext.processPendingChanges()

        await waitUntil {
            state.visibleMessages.map(\.objectID) == [message.objectID] &&
                state.totalMessageCount == 1 &&
                state.initialLoadPhase == .loaded &&
                !state.isLoadingMore
        }
    }

    func testInternalDateUpdateReordersLatestWindow() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 5)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
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
            state.visibleMessages.map(\.objectID) ==
                Array(messages.suffix(3)).map(\.objectID)
        }

        messages[0].internalDate = Date(timeIntervalSince1970: 10)
        try viewContext.save()

        let expectedIDs = [messages[3], messages[4], messages[0]].map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 5 &&
                state.isShowingLatestWindow &&
                !state.isLoadingMore
        }
    }

    func testBackgroundInternalDateMergeReordersLatestWindow() async throws {
        stack = TestCoreDataStack(automaticallyMergesChanges: true)
        viewContext = stack.viewContext
        let (conversation, messages) = try makeConversationWithMessages(count: 5)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
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
            state.visibleMessages.map(\.objectID) ==
                Array(messages.suffix(3)).map(\.objectID)
        }

        let movedMessageID = messages[0].objectID
        let backgroundContext = stack.newBackgroundContext()
        try await backgroundContext.perform {
            let movedMessage = try XCTUnwrap(
                backgroundContext.existingObject(with: movedMessageID) as? Message
            )
            movedMessage.internalDate = Date(timeIntervalSince1970: 10)
            try backgroundContext.save()
        }

        let expectedIDs = [messages[3], messages[4], messages[0]].map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.totalMessageCount == 5 &&
                state.isShowingLatestWindow &&
                !state.isLoadingMore
        }
    }

    func testBackgroundOffWindowReadMergeDoesNotReloadLatestWindow() async throws {
        stack = TestCoreDataStack(automaticallyMergesChanges: true)
        viewContext = stack.viewContext
        let viewContext = self.viewContext!
        let fixture = try await viewContext.perform {
            let conversation = ConversationBuilder()
                .visible()
                .recentlyActive()
                .build(in: viewContext)
            var messages: [Message] = []
            for index in 0..<8 {
                let message = MessageBuilder()
                    .withId("virtual-scroll-\(index)")
                    .withSubject("virtual-scroll-\(index)")
                    .withDate(Date(timeIntervalSince1970: TimeInterval(index)))
                    .inConversation(conversation)
                    .build(in: viewContext)
                messages.append(message)
            }
            messages[0].isUnread = true
            try viewContext.save()
            return (
                conversationID: conversation.id.uuidString,
                expectedIDs: Array(messages.suffix(3)).map(\.objectID),
                offWindowMessageID: messages[0].objectID
            )
        }

        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let requestedRanges = RangeRecorder()
        let stack = self.stack!
        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await requestedRanges.record(range)
            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }
        let state = VirtualScrollState(
            conversationId: fixture.conversationID,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) == fixture.expectedIDs &&
                !state.isLoadingMore
        }

        let backgroundContext = stack.newBackgroundContext()
        try await backgroundContext.perform {
            let message = try XCTUnwrap(
                backgroundContext.existingObject(
                    with: fixture.offWindowMessageID
                ) as? Message
            )
            message.isUnread = false
            message.localModifiedAt = Date()
            try backgroundContext.save()
        }

        await waitUntilInContext(viewContext) { context in
            guard let message = try? context.existingObject(
                with: fixture.offWindowMessageID
            ) as? Message else {
                return false
            }
            return message.isUnread == false
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let nonemptyRanges = await requestedRanges.snapshot().filter { !$0.isEmpty }
        XCTAssertEqual(nonemptyRanges, [5..<8])
        XCTAssertEqual(state.visibleMessages.map(\.objectID), fixture.expectedIDs)
        XCTAssertEqual(state.totalMessageCount, 8)
        XCTAssertEqual(state.initialLoadPhase, .loaded)
    }

    func testPostSyncReconcilesOffWindowMessageMovedOutOfConversation() async throws {
        stack = TestCoreDataStack(automaticallyMergesChanges: true)
        viewContext = stack.viewContext
        let viewContext = self.viewContext!
        let fixture = try await viewContext.perform {
            let conversation = ConversationBuilder()
                .visible()
                .recentlyActive()
                .build(in: viewContext)
            var messages: [Message] = []
            for index in 0..<5 {
                let message = MessageBuilder()
                    .withId("virtual-scroll-\(index)")
                    .withSubject("virtual-scroll-\(index)")
                    .withDate(Date(timeIntervalSince1970: TimeInterval(index)))
                    .inConversation(conversation)
                    .build(in: viewContext)
                messages.append(message)
            }
            let destination = ConversationBuilder()
                .visible()
                .recentlyActive()
                .build(in: viewContext)
            try viewContext.save()
            return (
                conversationID: conversation.id.uuidString,
                expectedIDs: Array(messages.suffix(3)).map(\.objectID),
                movedMessageID: messages[0].objectID,
                destinationID: destination.objectID
            )
        }

        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: fixture.conversationID,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) == fixture.expectedIDs &&
                state.totalMessageCount == 5
        }

        let backgroundContext = stack.newBackgroundContext()
        try await backgroundContext.perform {
            let movedMessage = try XCTUnwrap(
                backgroundContext.existingObject(
                    with: fixture.movedMessageID
                ) as? Message,
                "Expected the saved source message to materialize as Message"
            )
            let destination = try XCTUnwrap(
                backgroundContext.existingObject(
                    with: fixture.destinationID
                ) as? Conversation,
                "Expected the saved destination to materialize as Conversation"
            )
            movedMessage.conversation = destination
            try backgroundContext.save()
        }

        await waitUntilInContext(viewContext) { context in
            guard let message = try? context.existingObject(
                with: fixture.movedMessageID
            ) as? Message else {
                return false
            }
            return message.conversation?.objectID == fixture.destinationID
        }
        NotificationCenter.default.post(name: .syncCompleted, object: nil)

        await waitUntil {
            state.visibleMessages.map(\.objectID) == fixture.expectedIDs &&
                state.totalMessageCount == 4 &&
                state.isShowingLatestWindow &&
                !state.isLoadingMore
        }
    }

    func testPostSyncValidationRetriesOneTransientFetchFailure() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 5)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let requestCounter = InitialLoadAttemptCounter()
        let requestedRanges = RangeRecorder()
        let stack = self.stack!
        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let requestNumber = await requestCounter.next()
            await requestedRanges.record(range)
            if requestNumber == 3 {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 5,
                    fetchErrorDescription: "Transient validation failure"
                )
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
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(3)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                !state.isLoadingMore
        }

        NotificationCenter.default.post(name: .syncCompleted, object: nil)
        await waitUntilRecordedRangeCount(4, in: requestedRanges)

        let recordedRanges = await requestedRanges.snapshot()
        XCTAssertEqual(
            recordedRanges,
            [0..<0, 2..<5, 2..<5, 2..<5]
        )
        XCTAssertEqual(state.visibleMessages.map(\.objectID), expectedIDs)
        XCTAssertEqual(state.totalMessageCount, 5)
    }

    func testPostSyncValidationRevalidatesWindowChangedDuringValidation() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 6)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = RequestNumberPause(targetRequest: 2)
        let requestedRanges = RangeRecorder()
        let stack = self.stack!
        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            await requestedRanges.record(range)
            let page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
            await pause.waitIfNeeded()
            return page
        }
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) ==
                Array(messages.prefix(3)).map(\.objectID)
        }

        NotificationCenter.default.post(name: .syncCompleted, object: nil)
        await pause.waitUntilPaused()

        state.markIndexVisible(3)
        await waitUntilRecordedRangeCount(4, in: requestedRanges)
        await waitUntil {
            state.visibleRangeStartIndex == 2 &&
                state.visibleMessages.map(\.objectID) ==
                    Array(messages[2..<6]).map(\.objectID)
        }
        await pause.release()
        await waitUntilRecordedRangeCount(5, in: requestedRanges)

        let recordedRanges = await requestedRanges.snapshot()
        XCTAssertEqual(
            recordedRanges,
            [0..<3, 0..<3, 2..<6, 3..<6, 2..<6]
        )
        XCTAssertEqual(state.visibleRangeStartIndex, 2)
        XCTAssertEqual(
            state.visibleMessages.map(\.objectID),
            Array(messages[2..<6]).map(\.objectID)
        )
        XCTAssertEqual(state.totalMessageCount, 6)
        XCTAssertFalse(state.isLoadingMore)
    }

    func testWindowLoadReclampsAfterDatasetShrinksWhilePageIsLoading() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 12)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 3,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let pause = MatchingRangePause(targetRange: 7..<12)
        let stack = self.stack!
        let loader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            let page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
            await pause.waitIfNeeded(for: range)
            return page
        }
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: loader
        )
        defer { state.cleanup() }

        await waitUntil {
            state.visibleMessages.map(\.objectID) ==
                Array(messages.prefix(3)).map(\.objectID)
        }

        state.markIndexVisible(8)
        await pause.waitUntilPaused()

        for message in messages.prefix(10) {
            viewContext.delete(message)
        }
        viewContext.processPendingChanges()
        try viewContext.save()
        await pause.release()

        let expectedIDs = Array(messages.suffix(2)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs &&
                state.visibleRangeStartIndex == 0 &&
                state.totalMessageCount == 2 &&
                state.isShowingLatestWindow &&
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

    private func waitUntilInContext(
        _ context: NSManagedObjectContext,
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping (NSManagedObjectContext) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await context.perform({ condition(context) }) {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for context condition", file: file, line: line)
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

private actor InitialLoadAttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func snapshot() -> Int {
        count
    }
}

private actor RequestNumberPause {
    private let targetRequest: Int
    private var requestCount = 0
    private var isPaused = false
    private var isReleased = false

    init(targetRequest: Int) {
        self.targetRequest = targetRequest
    }

    func waitIfNeeded() async {
        requestCount += 1
        guard requestCount == targetRequest else { return }

        isPaused = true
        while !isReleased && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitUntilPaused() async {
        while !isPaused {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func release() {
        isReleased = true
    }
}

private actor MatchingRangePause {
    private let targetRange: Range<Int>
    private var isPaused = false
    private var isReleased = false

    init(targetRange: Range<Int>) {
        self.targetRange = targetRange
    }

    func waitIfNeeded(for range: Range<Int>) async {
        guard range == targetRange, !isPaused else { return }

        isPaused = true
        while !isReleased && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitUntilPaused() async {
        while !isPaused {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func release() {
        isReleased = true
    }
}

private actor RequestSequencePause {
    private let targetRequests: [Int]
    private var requestCount = 0
    private var pausedStages = Set<Int>()
    private var releasedStages = Set<Int>()

    init(targetRequests: [Int]) {
        self.targetRequests = targetRequests
    }

    func waitIfNeeded() async {
        requestCount += 1
        guard let stage = targetRequests.firstIndex(of: requestCount) else {
            return
        }

        pausedStages.insert(stage)
        while !releasedStages.contains(stage) && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitUntilPaused(stage: Int) async {
        while !pausedStages.contains(stage) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func release(stage: Int) {
        releasedStages.insert(stage)
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
