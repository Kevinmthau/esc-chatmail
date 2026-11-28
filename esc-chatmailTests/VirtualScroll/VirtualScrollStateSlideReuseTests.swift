import XCTest
import CoreData
@testable import esc_chatmail

/// What a scroll step costs the main thread (architecture review 2026-11,
/// chat-transcript-ui#2): the sliding replace maps only the rows the window
/// did not hold, and the grouping's read of the rows just outside the window
/// is a lookup by the ID the window's load read, not an OFFSET fetch.
///
/// The view context is a `MainQueueFetchRecordingContext`, a main-queue
/// context like `TestCoreDataStack.makeMainQueueViewContext()`'s, which
/// records each `Message` fetch `VirtualScrollState` runs on it. Every
/// fixture, save and assertion goes through it. The page loads run on
/// background contexts and are not recorded.
@MainActor
final class VirtualScrollStateSlideReuseTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: MainQueueFetchRecordingContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = MainQueueFetchRecordingContext.make(retiredWith: stack)
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Sliding replace

    /// A slide from 0..<3 to 2..<7 holds row 2 already: only rows 3..<7 are
    /// fetched and mapped, in one `SELF IN` of their four IDs.
    ///
    /// Revert-check: `reusesCachedRows: extendsWindow` in
    /// `VirtualScrollState.updateVisibleMessages` fetches all five rows
    /// (`[5]`).
    func testSlideReplace_mapsOnlyTheRowsTheWindowDidNotHold() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 10)
        defer { state.cleanup() }
        viewContext.resetRecordedFetches()

        state.markIndexVisible(3)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 2 }

        XCTAssertEqual(
            state.visibleMessages.map(\.objectID),
            Array(messages[2..<7]).map(\.objectID)
        )
        XCTAssertEqual(viewContext.messageFetches.compactMap(\.selfInIDCount), [4])
    }

    /// A row the window holds that changed before the slide is shown as it is
    /// now: a reused row is one the view context's change kept fresh.
    ///
    /// Revert-check: dropping `invalidateCachedRows(for: affectedMessageIDs)`
    /// in `VirtualScrollState.handleViewContextChange` keeps the old subject.
    ///
    /// HONEST SCOPE: on main, where the slide re-mapped every row, this passes
    /// with that eviction removed; it pins that the reuse rests on it.
    func testSlideReplace_reusedRowChangedBeforehand_showsItsNewValue() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 10)
        defer { state.cleanup() }

        messages[2].subject = "changed before the slide"
        try viewContext.save()
        state.markIndexVisible(3)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 2 }

        XCTAssertEqual(state.visibleMessages.first?.objectID, messages[2].objectID)
        XCTAssertEqual(state.visibleMessages.first?.subject, "changed before the slide")
    }

    // MARK: - Off screen

    /// A row changed while the chat was off screen (a full-screen Quick Look
    /// runs `cleanup()`, which stops the change observation) is shown as it is
    /// now once the chat is back: `resume()`'s full re-map heals it. The
    /// control for the two below.
    func testResumeAlone_rowChangedWhileOffScreen_showsItsNewValue() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 10)
        defer { state.cleanup() }
        state.cleanup()
        messages[1].subject = "changed while off screen"
        try viewContext.save()

        state.resume()
        await waitUntil { state.visibleMessages.count == 3 && state.visibleMessages[1].subject == "changed while off screen" }

        XCTAssertEqual(state.visibleMessages[1].subject, "changed while off screen")
    }

    /// The rows reappearing slide the window in the turn the chat resumes,
    /// which supersedes `resume()`'s re-map; the slide re-maps every row,
    /// because none of the cached ones is trusted after the chat was off
    /// screen. Found by the PR 529 review's probe.
    ///
    /// Revert-check: dropping both calls of
    /// `VirtualScrollState.discardRowCacheNothingObserved()` (in `cleanup()` and
    /// `resume()`) keeps the old subject; either one alone keeps this passing.
    func testResumeThenSlide_rowChangedWhileOffScreen_showsItsNewValue() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 10)
        defer { state.cleanup() }
        state.cleanup()
        messages[2].subject = "changed while off screen"
        try viewContext.save()

        state.resume()
        state.markIndexVisible(3)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 2 }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state.visibleRangeStartIndex, 2)
        XCTAssertEqual(state.visibleMessages.first?.objectID, messages[2].objectID)
        XCTAssertEqual(state.visibleMessages.first?.subject, "changed while off screen")
    }

    /// The same with the slide started before `resume()`, as when a row's
    /// `onAppear` runs before the chat's.
    ///
    /// Revert-check: dropping both calls of
    /// `VirtualScrollState.discardRowCacheNothingObserved()` (in `cleanup()` and
    /// `resume()`) keeps the old subject; either one alone keeps this passing.
    func testSlideThenResume_rowChangedWhileOffScreen_showsItsNewValue() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 10)
        defer { state.cleanup() }
        state.cleanup()
        messages[2].subject = "changed while off screen"
        try viewContext.save()

        state.markIndexVisible(3)
        state.resume()
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 2 }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state.visibleRangeStartIndex, 2)
        XCTAssertEqual(state.visibleMessages.first?.objectID, messages[2].objectID)
        XCTAssertEqual(state.visibleMessages.first?.subject, "changed while off screen")
    }

    /// A row read while the chat is off screen (a body pass's
    /// `messageRow(absoluteIndex + 1)`) refills the cache `cleanup()` emptied,
    /// and a change after that is not observed either: `resume()` drops the
    /// cache again before the observation restarts, so the slide on return
    /// re-maps it. Found by the review of PR 529's fix.
    ///
    /// Revert-check: dropping the `discardRowCacheNothingObserved()` call from
    /// `VirtualScrollState.resume()` keeps the old subject.
    func testRowRefilledWhileOffScreenThenChanged_resumeThenSlide_showsItsNewValue() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 10)
        defer { state.cleanup() }
        state.cleanup()
        _ = state.rowForGrouping(atAbsoluteIndex: 2)
        messages[2].subject = "changed while off screen"
        try viewContext.save()

        state.resume()
        state.markIndexVisible(3)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 2 }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state.visibleRangeStartIndex, 2)
        XCTAssertEqual(state.visibleMessages.first?.objectID, messages[2].objectID)
        XCTAssertEqual(state.visibleMessages.first?.subject, "changed while off screen")
    }

    /// A slide whose load lands before the chat resumes (a row's `onAppear`
    /// before the chat's, and the page back first) publishes rows mapped then,
    /// not the ones cached before the chat left the screen.
    ///
    /// Revert-check: dropping the `discardRowCacheNothingObserved()` call from
    /// `VirtualScrollState.cleanup()` keeps the old subject.
    func testSlideLandingBeforeResume_rowChangedWhileOffScreen_showsItsNewValue() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 10)
        defer { state.cleanup() }
        state.cleanup()
        messages[2].subject = "changed while off screen"
        try viewContext.save()

        state.markIndexVisible(3)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 2 }

        XCTAssertEqual(state.visibleMessages.first?.objectID, messages[2].objectID)
        XCTAssertEqual(state.visibleMessages.first?.subject, "changed while off screen")
    }

    // MARK: - Neighbours

    /// After a slide publishes the historical window 11..<16, the grouping's
    /// rows on either side of it are read by ID with no OFFSET fetch.
    ///
    /// Revert-check: dropping the `neighborID` lookup in
    /// `VirtualScrollState.rowForGrouping` records fetches at offsets 16 and
    /// 10; so does `VirtualScrollState.loadMessagePage` fetching its range
    /// alone (`range` for `neighborFetchRange(for:)`, no
    /// `splittingNeighbors`).
    func testSlidWindow_groupingRowsEitherSide_areReadByID() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 30)
        defer { state.cleanup() }
        state.markIndexVisible(12)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 11 }
        XCTAssertEqual(state.messageWindow?.range, 11..<16)
        viewContext.resetRecordedFetches()

        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 16)?.objectID, messages[16].objectID)
        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 10)?.objectID, messages[10].objectID)

        XCTAssertEqual(viewContext.messageFetches.map(\.fetchOffset), [0, 0])
        XCTAssertEqual(viewContext.messageFetches.compactMap(\.selfInIDCount), [1, 1])
    }

    /// The memo answers a second read: a body that asks on every publish
    /// fetches once per window.
    ///
    /// Revert-check: dropping `resolvedRowsByAbsoluteIndex[index] = row` from
    /// the neighbour branch of `VirtualScrollState.rowForGrouping` fetches
    /// three times.
    func testSlidWindow_groupingRowAfterIt_isFetchedOncePerWindow() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 30)
        defer { state.cleanup() }
        state.markIndexVisible(12)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 11 }
        viewContext.resetRecordedFetches()

        for _ in 0..<3 {
            XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 16)?.objectID, messages[16].objectID)
        }

        XCTAssertEqual(viewContext.messageFetches.count, 1)
    }

    /// A preload below the window takes the page's row below as the window's;
    /// the row above stays the one the slide read.
    ///
    /// Revert-check: `nextNeighborID: currentWindow.nextNeighborID` in
    /// `VirtualScrollState.preloadNext` (the old window's, which the
    /// extended window now holds) sends the read of row 19 to an OFFSET
    /// fetch.
    func testPreloadNext_groupingRowsEitherSide_areReadByID() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 30)
        defer { state.cleanup() }
        state.markIndexVisible(12)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 11 }

        state.preloadNext()
        await waitUntil { state.messageWindow?.range == 11..<19 }
        viewContext.resetRecordedFetches()

        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 19)?.objectID, messages[19].objectID)
        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 10)?.objectID, messages[10].objectID)
        XCTAssertEqual(viewContext.messageFetches.map(\.fetchOffset), [0, 0])
    }

    /// A preload above the window takes the page's row above as the window's;
    /// the row below stays the one the slide read.
    ///
    /// Revert-check: `previousNeighborID: currentWindow.previousNeighborID`
    /// in `VirtualScrollState.preloadPrevious` sends the read of row 7 to an
    /// OFFSET fetch.
    func testPreloadPrevious_groupingRowsEitherSide_areReadByID() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 30)
        defer { state.cleanup() }
        state.markIndexVisible(12)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 11 }

        state.preloadPrevious()
        await waitUntil { state.messageWindow?.range == 8..<16 }
        viewContext.resetRecordedFetches()

        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 7)?.objectID, messages[7].objectID)
        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 16)?.objectID, messages[16].objectID)
        XCTAssertEqual(viewContext.messageFetches.map(\.fetchOffset), [0, 0])
    }

    /// A message inserted between a kept historical window and the row its
    /// load read below it is the row there now: the insertion clears the
    /// neighbours, and the read finds the new row.
    ///
    /// Revert-check: keeping the window's neighbours on that insertion
    /// (`messageWindow` in place of `messageWindow?.clearingNextNeighborID()` in
    /// `VirtualScrollState.handleViewContextChange`) answers the old row 16,
    /// which still sorts after the window.
    func testInsertionPastKeptHistoricalWindow_groupingRowAfterIt_isTheInsertedRow() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 30)
        defer { state.cleanup() }
        state.markIndexVisible(12)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 11 }
        let conversation = try XCTUnwrap(messages[0].conversation)

        let inserted = makeMessage(id: "virtual-scroll-15b", date: 15.5, conversation: conversation)
        // Permanent before the change is posted, as a merged sync row's ID is:
        // the change handler counts no insertion with a temporary ID.
        try viewContext.obtainPermanentIDs(for: [inserted])
        try viewContext.save()

        XCTAssertEqual(state.messageWindow?.range, 11..<16, "The insertion past the window keeps it")
        XCTAssertEqual(state.totalMessageCount, 31)
        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 16)?.objectID, inserted.objectID)
    }

    /// An insertion that sorts after the window cannot come between it and the
    /// row above it, so that neighbour is kept: on the Mac the first row's time
    /// line reads it, and every sync arrival in a historical window sent that
    /// read to the OFFSET fetch.
    ///
    /// Revert-check: clearing both neighbours for every count-raising insertion
    /// in `VirtualScrollState.handleViewContextChange` (`clearingNeighborIDs()`
    /// in place of `clearingNextNeighborID()`) records a fetch at offset 10.
    func testInsertionPastKeptHistoricalWindow_groupingRowAboveIt_isStillReadByID() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 30)
        defer { state.cleanup() }
        state.markIndexVisible(12)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 11 }
        let conversation = try XCTUnwrap(messages[0].conversation)

        let inserted = makeMessage(id: "virtual-scroll-25b", date: 25.5, conversation: conversation)
        try viewContext.obtainPermanentIDs(for: [inserted])
        try viewContext.save()
        XCTAssertEqual(state.messageWindow?.range, 11..<16, "The insertion past the window keeps it")
        viewContext.resetRecordedFetches()

        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 10)?.objectID, messages[10].objectID)
        XCTAssertEqual(viewContext.messageFetches.map(\.fetchOffset), [0])
    }

    /// A neighbour the transcript no longer selects (it was given a label the
    /// chat leaves out, and no change reached the view context) is not
    /// answered: the read falls back to the OFFSET fetch, which reads the row
    /// there now.
    ///
    /// Revert-check: fetching the neighbour by `SELF IN` alone in
    /// `VirtualScrollState.resolveNeighborRow` answers the trashed row.
    func testNeighborLeftTheTranscript_groupingRowAfterWindow_fallsBackToTheRowThereNow() async throws {
        let (state, messages) = try await makeLoadedState(messageCount: 30)
        defer { state.cleanup() }
        state.markIndexVisible(12)
        await waitUntil { !state.isLoadingMore && state.visibleRangeStartIndex == 11 }
        let neighborID = messages[16].objectID

        let background = stack.newBackgroundContext()
        try await background.perform {
            let message = try XCTUnwrap(try background.existingObject(with: neighborID) as? Message)
            message.addToLabels(LabelBuilder().trash().build(in: background))
            try background.save()
        }
        viewContext.resetRecordedFetches()

        XCTAssertEqual(state.rowForGrouping(atAbsoluteIndex: 16)?.objectID, messages[17].objectID)
        XCTAssertEqual(viewContext.messageFetches.map(\.fetchOffset), [0, 16])
    }

    // MARK: - Page loaders

    /// A page load reads the rows on either side of its range in the same
    /// query, and its rows are the range's alone.
    ///
    /// Revert-check: `VirtualScrollState.loadMessagePage` fetching its range
    /// alone (`range` for `neighborFetchRange(for:)`, no `splittingNeighbors`)
    /// leaves the neighbours nil and the rows as they are.
    func testLoadMessagePage_readsTheRowsEitherSideOfItsRange() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let ids = messages.map(\.objectID)

        let middle = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 2..<5,
            in: stack.newBackgroundContext()
        )
        XCTAssertEqual(middle.messageIDs, Array(ids[2..<5]))
        XCTAssertEqual(middle.previousNeighborID, ids[1])
        XCTAssertEqual(middle.nextNeighborID, ids[5])
        XCTAssertEqual(middle.totalCount, 8)

        let head = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 0..<3,
            in: stack.newBackgroundContext()
        )
        XCTAssertEqual(head.messageIDs, Array(ids[0..<3]))
        XCTAssertNil(head.previousNeighborID)
        XCTAssertEqual(head.nextNeighborID, ids[3])

        let pastTheEnd = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 6..<10,
            in: stack.newBackgroundContext()
        )
        XCTAssertEqual(pastTheEnd.messageIDs, Array(ids[6..<8]))
        XCTAssertEqual(pastTheEnd.previousNeighborID, ids[5])
        XCTAssertNil(pastTheEnd.nextNeighborID)

        let countOnly = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 3..<3,
            in: stack.newBackgroundContext()
        )
        XCTAssertEqual(countOnly.messageIDs, [])
        XCTAssertNil(countOnly.previousNeighborID)
        XCTAssertNil(countOnly.nextNeighborID)
        XCTAssertEqual(countOnly.totalCount, 8)
    }

    /// The view-context loader the latest window takes with pending inserts
    /// reads the neighbours the same way.
    ///
    /// Revert-check: `VirtualScrollState.loadPendingMessagePage` fetching its
    /// range alone (`range` for `neighborFetchRange(for:)`, no
    /// `splittingNeighbors`) leaves both neighbours nil.
    func testLoadPendingMessagePage_readsTheRowsEitherSideOfItsRange() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let ids = messages.map(\.objectID)

        let page = await VirtualScrollState.loadPendingMessagePage(
            conversationId: conversation.id.uuidString,
            range: 2..<5,
            in: viewContext
        )

        XCTAssertEqual(page.messageIDs, Array(ids[2..<5]))
        XCTAssertEqual(page.previousNeighborID, ids[1])
        XCTAssertEqual(page.nextNeighborID, ids[5])
        XCTAssertEqual(page.totalCount, 8)
    }

    /// What a shrunk dataset leaves the split: fewer rows than the range, as an
    /// unwidened fetch would give, for the callers' exact-count checks.
    func testSplittingNeighbors_shortFetch_yieldsFewerRowsAndNoRowBelow() {
        let split = VirtualScrollMessagePage.splittingNeighbors(
            [1, 2, 3],
            requestedRange: 4..<8
        )
        XCTAssertEqual(split.previous, 1)
        XCTAssertEqual(split.rows, [2, 3])
        XCTAssertNil(split.next)

        let full = VirtualScrollMessagePage.splittingNeighbors(
            [3, 4, 5, 6, 7, 8],
            requestedRange: 4..<8
        )
        XCTAssertEqual(full.previous, 3)
        XCTAssertEqual(full.rows, [4, 5, 6, 7])
        XCTAssertEqual(full.next, 8)
    }

    // MARK: - Trims

    /// A trim's dropped edge row is the trimmed window's neighbour on that
    /// side, and the other side's is kept.
    ///
    /// Revert-check: dropping `nextNeighborID: messageIDs[messageIDs.count - overflow]`
    /// from `MessageWindow.backTrimmed`, or `previousNeighborID: messageIDs[overflow - 1]`
    /// from `frontTrimmed`.
    func testTrims_droppedEdgeRowBecomesTheNeighbour() throws {
        let (_, messages) = try makeConversationWithMessages(count: 6)
        let ids = messages.map(\.objectID)
        let window = MessageWindow(
            startIndex: 10,
            endIndex: 16,
            messageIDs: ids,
            isLoading: false,
            previousNeighborID: nil,
            nextNeighborID: nil
        )

        let back = window.backTrimmed(to: 4)
        XCTAssertEqual(back.range, 10..<14)
        XCTAssertEqual(back.nextNeighborID, ids[4])
        XCTAssertEqual(back.neighborID(atAbsoluteIndex: 14), ids[4])
        XCTAssertNil(back.previousNeighborID)

        let front = window.frontTrimmed(to: 4)
        XCTAssertEqual(front.range, 12..<16)
        XCTAssertEqual(front.previousNeighborID, ids[1])
        XCTAssertEqual(front.neighborID(atAbsoluteIndex: 11), ids[1])
        XCTAssertNil(front.nextNeighborID)
    }

    // MARK: - Helpers

    /// A loaded state over `messageCount` messages with the window 0..<3 and a
    /// configuration whose position rows are 5 wide (3 from the position down,
    /// a buffer of 1 each side) and which preloads nothing on its own
    /// (threshold 0), so only the test moves the window.
    private func makeLoadedState(
        messageCount: Int
    ) async throws -> (VirtualScrollState, [Message]) {
        let (conversation, messages) = try makeConversationWithMessages(count: messageCount)
        let stack = self.stack!
        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: VirtualScrollConfiguration(
                visibleItemCount: 3,
                bufferSize: 1,
                pageSize: 3,
                preloadThreshold: 0
            ),
            initialWindowPosition: .beginning,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        await waitUntil {
            state.visibleMessages.map(\.objectID) == Array(messages.prefix(3)).map(\.objectID) &&
                !state.isLoadingMore
        }
        return (state, messages)
    }

    private func makeConversationWithMessages(count: Int) throws -> (Conversation, [Message]) {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)

        var messages: [Message] = []
        for index in 0..<count {
            messages.append(makeMessage(
                id: "virtual-scroll-\(String(format: "%02d", index))",
                date: TimeInterval(index),
                conversation: conversation
            ))
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

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
