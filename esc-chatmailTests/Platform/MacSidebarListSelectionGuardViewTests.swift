#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// The view that stops a list drawing its own selection under the Mac sidebar's fill. These run
/// in `Mac.xctestplan` only: the view is AppKit.
///
/// Five things are pinned: that the guard finds its list's table from a row and from behind
/// the list, that it turns the table's own selection off, and that it never does so from
/// inside a call made while the list is being laid out. The write reloads the table, and made
/// there it was logged as a fault by SwiftUI at the first click on a row
/// (`MacSidebarListSelectionGuardView`). Then the two bounds: a guard that found no table goes
/// on looking for a while and then stops, and a table that does not keep the style is written
/// a few times and then left alone.
///
/// HONEST SCOPE: the tables here are AppKit's own, built by hand. That pins what the guard does
/// to an `NSTableView` it is inside or behind, and when. That SwiftUI's `List` is such a table,
/// with a row's background inside it and the list's background beside it, is pinned by
/// `MacSidebarRowSelectionBackgroundTests` and `MacConversationSidebarSelectionGuardTests`, which
/// mount real lists. What a table with the style `.none` then draws, and what the system logs
/// when the write is made inside a layout, were measured in throwaway programs, not seen in the
/// app.
@MainActor
final class MacSidebarListSelectionGuardViewTests: XCTestCase {
    // MARK: - In a row, where a selected row's fill has it

    /// Revert-check: deleting `tableView.selectionHighlightStyle = .none` from
    /// `MacSidebarListSelectionGuardView.turnOffListTableViewSelection` makes this fail.
    func testGuard_insideATablesRow_turnsOffTheTablesOwnSelection() async throws {
        let table = makeTable()
        XCTAssertEqual(table.tableView.selectionHighlightStyle, .regular, "a table draws its selection")
        let guardView = MacSidebarListSelectionGuardView()

        table.rowContent.addSubview(guardView)

        XCTAssertTrue(guardView.guardedTableView === table.tableView)
        try await waitUntil { table.tableView.selectionHighlightStyle == .none }
    }

    /// SwiftUI did not set the style back in the measurements. If something does, the next
    /// layout of a guard notices, and turns it off again.
    ///
    /// Revert-check: deleting `guardListTableView()` from
    /// `MacSidebarListSelectionGuardView.layout` makes this fail.
    func testGuard_styleSetBack_isTurnedOffAgainAfterTheNextLayout() async throws {
        let table = makeTable()
        let guardView = MacSidebarListSelectionGuardView()
        table.rowContent.addSubview(guardView)
        try await waitUntil { table.tableView.selectionHighlightStyle == .none }

        table.tableView.selectionHighlightStyle = .regular
        guardView.layout()

        try await waitUntil { table.tableView.selectionHighlightStyle == .none }
    }

    /// The table is the one the guard is inside, however far up. In a SwiftUI list it was four
    /// superviews up.
    ///
    /// Revert-check: returning `superview as? NSTableView` from
    /// `MacSidebarListSelectionGuardView.enclosingTableView` makes this fail.
    func testGuard_severalViewsDeepInATable_stillFindsIt() async throws {
        let table = makeTable()
        let inner = NSView()
        let innermost = NSView()
        table.rowContent.addSubview(inner)
        inner.addSubview(innermost)
        let guardView = MacSidebarListSelectionGuardView()

        innermost.addSubview(guardView)

        XCTAssertTrue(guardView.guardedTableView === table.tableView)
        try await waitUntil { table.tableView.selectionHighlightStyle == .none }
    }

    func testGuard_withNoTableAboutIt_guardsNothing() async {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let guardView = MacSidebarListSelectionGuardView()

        container.addSubview(guardView)
        guardView.guardListTableView()
        // The turn the guard asked for, in which it looks once more.
        await mainQueueTurn()

        XCTAssertNil(guardView.guardedTableView)
    }

    /// The style changes what the table draws, not what it selects: the selection the sidebar
    /// reads is still the table's.
    func testGuard_leavesTheTablesSelectionAlone() async throws {
        let table = makeTable()
        table.tableView.selectRowIndexes([1], byExtendingSelection: false)
        let guardView = MacSidebarListSelectionGuardView()

        table.rowContent.addSubview(guardView)
        try await waitUntil { table.tableView.selectionHighlightStyle == .none }

        XCTAssertEqual(table.tableView.selectedRowIndexes, [1])
    }

    /// Revert-check: deleting the `hitTest(_:)` override from `MacSidebarListSelectionGuardView`
    /// makes this fail: a guard with a size would take the click meant for its row.
    func testGuard_takesNoClicks() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.addSubview(guardView)

        XCTAssertNil(guardView.hitTest(NSPoint(x: 50, y: 50)))
    }

    // MARK: - When it writes

    /// Every call the guard hears about its list from is made while the list is being put
    /// together or laid out: joining a superview, `layout()`, and SwiftUI's update of the view
    /// (`MacSidebarListSelectionGuard.updateNSView`). None of them writes. The write waits for
    /// the next turn of the main queue, and three calls in one turn are one write.
    ///
    /// Revert-check: calling `turnOffListTableViewSelection()` in place of `scheduleTurnOff()`
    /// in `MacSidebarListSelectionGuardView.guardListTableView` makes this fail: the table's
    /// style is written inside the first call.
    func testGuard_calledWhileItsListIsPutTogether_writesNothingUntilTheNextTurnOfTheMainQueue() async throws {
        let table = makeTable()
        let writesBefore = table.tableView.styleWrites
        let guardView = MacSidebarListSelectionGuardView()

        table.rowContent.addSubview(guardView)
        guardView.layout()
        guardView.guardListTableView()

        XCTAssertTrue(guardView.guardedTableView === table.tableView, "The table is found at once")
        XCTAssertEqual(table.tableView.styleWrites, writesBefore, "The guard wrote the table's style from inside a call")
        XCTAssertEqual(table.tableView.selectionHighlightStyle, .regular)

        try await waitUntil { table.tableView.selectionHighlightStyle == .none }
        await mainQueueTurn()
        XCTAssertEqual(table.tableView.styleWrites, writesBefore + 1)
    }

    /// The case the first native build logged a fault for: the guard is in a row the table
    /// makes while it lays itself out, as a selected row's fill is. A real table, in a window,
    /// makes its rows inside one layout pass here, and by the end of that pass the guards in
    /// them have been laid out and have written nothing.
    ///
    /// Revert-check: either of these makes this fail, with the style written before the layout
    /// pass has returned. Calling `turnOffListTableViewSelection()` in place of
    /// `guardListTableView()` in `MacSidebarListSelectionGuardView.layout`, which is the write
    /// back inside `layout()`. Or calling it in place of `scheduleTurnOff()` in
    /// `guardListTableView`.
    func testGuard_inRowsATableMakesInALayoutPass_writesNothingBeforeThePassEnds() async throws {
        let rows = GuardedRows(count: 3)
        let list = try makeTableInWindow(rows: rows)
        let writesBefore = list.tableView.styleWrites

        list.window.contentView?.layoutSubtreeIfNeeded()

        let guardViews = rows.guardViews
        XCTAssertFalse(guardViews.isEmpty, "The table made no rows in the layout pass, so this pins nothing")
        XCTAssertTrue(
            guardViews.contains { $0.guardedTableView === list.tableView },
            "No guard found the table during the layout pass, so this pins nothing"
        )
        XCTAssertEqual(
            list.tableView.styleWrites,
            writesBefore,
            "The table's style was written inside the layout pass that made its rows"
        )
        XCTAssertEqual(list.tableView.selectionHighlightStyle, .regular)

        try await waitUntil { list.tableView.selectionHighlightStyle == .none }
        await mainQueueTurn()
        XCTAssertEqual(list.tableView.styleWrites, writesBefore + 1, "Three guards in one table are one write")
    }

    // MARK: - Behind a list, where the sidebar has it

    /// A list's own background is not inside its table: the two are side by side under one
    /// view, the table in a scroll view drawn over the background.
    ///
    /// Revert-check: returning `enclosingTableView()` alone from
    /// `MacSidebarListSelectionGuardView.listTableView` makes this fail.
    func testGuard_behindAList_turnsOffTheSelectionOfTheTableDrawnOverIt() async throws {
        let stage = try makeStageInWindow()
        let list = makeList(in: stage.container, frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 150, y: 200, width: 0, height: 0))

        stage.container.addSubview(guardView, positioned: .below, relativeTo: list.scrollView)

        XCTAssertTrue(guardView.guardedTableView === list.tableView)
        XCTAssertEqual(list.tableView.selectionHighlightStyle, .regular, "Nothing is written inside the call")
        try await waitUntil { list.tableView.selectionHighlightStyle == .none }
    }

    /// SwiftUI adds a list's views to the window after its background's, so when the guard
    /// joins the window its table is not there yet. In the measurements a later `layout()` of
    /// the guard found it. Nothing promises that call, so the guard also asks for a turn of the
    /// main queue when it finds no table, and looks again then.
    ///
    /// The views here are in no window, so nothing lays the guard out after the table has
    /// joined: the turn is the only thing that can find it.
    ///
    /// Revert-check: asking for the turn only when a table was found (`scheduleTurnOff()` inside
    /// `if let tableView, tableView.selectionHighlightStyle != .none` in
    /// `MacSidebarListSelectionGuardView.guardListTableView`) makes this fail.
    func testGuard_behindAListWhoseTableJoinsAfterIt_findsTheTableOnItsTurn() async throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 150, y: 200, width: 0, height: 0))
        container.addSubview(guardView)
        XCTAssertNil(guardView.guardedTableView)

        let list = makeList(in: container, frame: NSRect(x: 0, y: 0, width: 300, height: 400))

        try await waitUntil { list.tableView.selectionHighlightStyle == .none }
        XCTAssertTrue(guardView.guardedTableView === list.tableView)
    }

    /// The table is the one drawn over the guard, not the first one the search meets. A table
    /// somewhere else in the window is another list's, and its selection is its own.
    ///
    /// Revert-check: returning true from `MacSidebarListSelectionGuardView.isDrawn(_:over:)`
    /// makes this fail: the guard takes the table beside it, which the search meets first.
    func testGuard_behindAList_leavesATableBesideItAlone() async throws {
        let stage = try makeStageInWindow()
        // Added first, so a search of the container's views meets it first.
        let other = makeList(in: stage.container, frame: NSRect(x: 320, y: 0, width: 300, height: 400))
        let list = makeList(in: stage.container, frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 150, y: 200, width: 0, height: 0))

        stage.container.addSubview(guardView, positioned: .below, relativeTo: other.scrollView)

        XCTAssertTrue(guardView.guardedTableView === list.tableView)
        try await waitUntil { list.tableView.selectionHighlightStyle == .none }
        await mainQueueTurn()
        XCTAssertEqual(other.tableView.selectionHighlightStyle, .regular)
    }

    /// With no table over it the guard finds none, however many there are elsewhere in the
    /// window.
    func testGuard_withATableOnlyBesideIt_guardsNothing() async throws {
        let stage = try makeStageInWindow()
        let other = makeList(in: stage.container, frame: NSRect(x: 320, y: 0, width: 300, height: 400))
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 150, y: 200, width: 0, height: 0))

        stage.container.addSubview(guardView)
        await mainQueueTurn()

        XCTAssertNil(guardView.guardedTableView)
        XCTAssertEqual(other.tableView.selectionHighlightStyle, .regular)
    }

    // MARK: - A table that joins late, or never

    /// The guard's own turn of the main queue comes and finds no table, and nothing lays the
    /// guard out afterwards: it has no size, so it is owed no second `layout()`. The table
    /// joins after that. Before the later looks the guard never found it, and the list's own
    /// selection stayed on until the first row was selected.
    ///
    /// The window's first layout pass is run before the table joins (`addWithItsOneLayout`).
    /// Left to come when it would, it came after the table had joined, laid the guard out, and
    /// found the table with no later look at all.
    ///
    /// Revert-check: deleting `scheduleLaterLook()` from
    /// `MacSidebarListSelectionGuardView.turnOffListTableViewSelection` makes this fail.
    func testGuard_behindAListWhoseTableJoinsAfterItsTurn_findsTheTableOnALaterLook() async throws {
        let stage = try makeStageInWindow()
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 150, y: 200, width: 0, height: 0))
        addWithItsOneLayout(guardView, to: stage)
        await mainQueueTurn()
        XCTAssertNil(guardView.guardedTableView, "The guard's turn found a table where there is none")

        let list = makeList(in: stage.container, frame: NSRect(x: 0, y: 0, width: 300, height: 400))

        try await waitUntil { list.tableView.selectionHighlightStyle == .none }
        XCTAssertTrue(guardView.guardedTableView === list.tableView)
        XCTAssertFalse(guardView.isLookPending, "The table is found and its selection is off: nothing is left to look for")
    }

    /// On a system that builds a list another way there is no table to find, and each look
    /// searches the window's views. So the looks end, and a table that joins after the last of
    /// them waits for a call from the list.
    ///
    /// Revert-check: deleting `laterLooksMade += 1` from
    /// `MacSidebarListSelectionGuardView.scheduleLaterLook` makes this fail: the guard goes on
    /// looking, and the wait for it to stop times out.
    func testGuard_withNoTableToFind_stopsLookingAfterItsLastLaterLook() async throws {
        let stage = try makeStageInWindow()
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 150, y: 200, width: 0, height: 0))
        guardView.laterLookDelays = [0.01, 0.01]
        addWithItsOneLayout(guardView, to: stage)
        XCTAssertTrue(guardView.isLookPending)

        try await waitUntil { !guardView.isLookPending }
        let list = makeList(in: stage.container, frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        await mainQueueTurn()

        XCTAssertNil(guardView.guardedTableView)
        XCTAssertEqual(list.tableView.selectionHighlightStyle, .regular)

        // A call from the list starts the looking over.
        guardView.layout()
        XCTAssertTrue(guardView.guardedTableView === list.tableView)
        try await waitUntil { list.tableView.selectionHighlightStyle == .none }
    }

    /// A call from the list is a new start: the later looks it gets are all of them, not what
    /// an earlier search left over.
    ///
    /// Revert-check: deleting `laterLooksMade = 0` from
    /// `MacSidebarListSelectionGuardView.scheduleTurnOff` makes this fail.
    func testGuard_calledByItsListAfterItsLooksRanOut_looksLaterAgain() async throws {
        let stage = try makeStageInWindow()
        let guardView = MacSidebarListSelectionGuardView(frame: NSRect(x: 150, y: 200, width: 0, height: 0))
        guardView.laterLookDelays = [0.01]
        addWithItsOneLayout(guardView, to: stage)
        try await waitUntil { !guardView.isLookPending }

        // Long enough for the table below to have joined before the look.
        guardView.laterLookDelays = [0.3]
        guardView.layout()
        await mainQueueTurn()
        XCTAssertTrue(guardView.isLookPending, "The turn after the list's call found no table and asked for no later look")
        let list = makeList(in: stage.container, frame: NSRect(x: 0, y: 0, width: 300, height: 400))

        try await waitUntil { list.tableView.selectionHighlightStyle == .none }
    }

    /// A guard in no window has no list to wait for. A selected row's fill is there when it
    /// joins its superview, and every selection would otherwise start three seconds of looks.
    ///
    /// Revert-check: deleting `window != nil` from the guard in
    /// `MacSidebarListSelectionGuardView.scheduleLaterLook` makes this fail.
    func testGuard_inNoWindow_asksForNoLaterLook() async {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let guardView = MacSidebarListSelectionGuardView()

        container.addSubview(guardView)
        XCTAssertTrue(guardView.isLookPending, "The guard asked for no turn, so this pins nothing")
        await mainQueueTurn()

        XCTAssertFalse(guardView.isLookPending)
    }

    // MARK: - A table that does not keep the style

    /// Nothing measured set the style back. If a system's table does, every time, each write
    /// reloads the table and the reload brings the next write: a reload at every turn of the
    /// main queue while a row is selected. The writes to one table are counted, and end.
    ///
    /// Revert-check: deleting `&& writesMade(to: tableView) < tableWriteLimit` from
    /// `MacSidebarListSelectionGuardView.needsTurnOff` makes this fail, with a write at every
    /// layout.
    func testGuard_inATableThatNeverKeepsTheStyle_stopsWritingAtTheLimit() async {
        let tableView = makeStyleForgettingTable()
        let guardView = MacSidebarListSelectionGuardView()
        tableView.addSubview(guardView)

        for _ in 0..<(MacSidebarListSelectionGuardView.tableWriteLimit + 4) {
            guardView.layout()
            await mainQueueTurn()
        }

        XCTAssertEqual(tableView.styleWrites, MacSidebarListSelectionGuardView.tableWriteLimit)
        XCTAssertFalse(guardView.isLookPending, "A guard with nothing left to write still asked for a turn")
    }

    /// The reload a write causes throws the selected row's fill away, and the guard in the new
    /// fill is a new view. So the count is kept on the table: counted by each guard, it would
    /// start again at every reload and never end.
    ///
    /// Revert-check: counting in a property of the guard, in place of the table's associated
    /// object in `MacSidebarListSelectionGuardView.writesMade(to:)`, makes this fail.
    func testGuard_inATableThatNeverKeepsTheStyle_sharesTheLimitWithEveryOtherGuardInIt() async {
        let tableView = makeStyleForgettingTable()

        for _ in 0..<(MacSidebarListSelectionGuardView.tableWriteLimit + 4) {
            // A new guard each time, as a fill's is after a reload.
            let guardView = MacSidebarListSelectionGuardView()
            tableView.addSubview(guardView)
            await mainQueueTurn()
            guardView.removeFromSuperview()
            await mainQueueTurn()
        }

        XCTAssertEqual(tableView.styleWrites, MacSidebarListSelectionGuardView.tableWriteLimit)
    }

    /// The limit is on writes, and a guard that finds the style already off makes none. A
    /// table that keeps the style is still turned off again when something sets it back,
    /// `tableWriteLimit` writes in all.
    func testGuard_styleSetBackOnce_isStillWithinTheLimit() async throws {
        let table = makeTable()
        let guardView = MacSidebarListSelectionGuardView()
        table.rowContent.addSubview(guardView)
        try await waitUntil { table.tableView.selectionHighlightStyle == .none }
        let writesBefore = table.tableView.styleWrites
        for _ in 0..<10 {
            guardView.layout()
            await mainQueueTurn()
        }
        XCTAssertEqual(table.tableView.styleWrites, writesBefore, "A layout that found the style off wrote it")

        table.tableView.selectionHighlightStyle = .regular
        guardView.layout()

        try await waitUntil { table.tableView.selectionHighlightStyle == .none }
    }

    // MARK: - Helpers

    /// The tables hold their data sources weakly.
    private var dataSources: [NSObject] = []

    override func tearDown() {
        dataSources = []
        super.tearDown()
    }

    private struct Table {
        let tableView: StyleRecordingTableView
        /// A view inside the table, standing for a row's content.
        let rowContent: NSView
    }

    /// A table in no window, with a view inside it for a guard to go in.
    private func makeTable() -> Table {
        let tableView = StyleRecordingTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        let dataSource = ThreeRows()
        tableView.dataSource = dataSource
        dataSources.append(dataSource)
        tableView.reloadData()
        let rowContent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tableView.addSubview(rowContent)
        return Table(tableView: tableView, rowContent: rowContent)
    }

    /// A table in no window that reports its own selection style whatever was written.
    private func makeStyleForgettingTable() -> StyleForgettingTableView {
        let tableView = StyleForgettingTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        let dataSource = ThreeRows()
        tableView.dataSource = dataSource
        dataSources.append(dataSource)
        tableView.reloadData()
        return tableView
    }

    private struct ScrollingTable {
        let scrollView: NSScrollView
        let tableView: StyleRecordingTableView
    }

    /// A table in a scroll view, as a list's is, added to `container`.
    private func makeList(in container: NSView, frame: NSRect) -> ScrollingTable {
        let scrollView = NSScrollView(frame: frame)
        let tableView = StyleRecordingTableView(frame: NSRect(origin: .zero, size: frame.size))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        let dataSource = ThreeRows()
        tableView.dataSource = dataSource
        dataSources.append(dataSource)
        scrollView.documentView = tableView
        container.addSubview(scrollView)
        return ScrollingTable(scrollView: scrollView, tableView: tableView)
    }

    private struct Stage {
        let window: NSWindow
        let container: NSView
    }

    /// A window that is never on screen, with one plain view for lists and guards to go in.
    private func makeStageInWindow() throws -> Stage {
        let window = try makeTestHostWindow()
        addTeardownBlock { @MainActor in
            window.close()
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = container
        return Stage(window: window, container: container)
    }

    /// Adds a guard to a window that holds no table, and runs the layout pass a window owes
    /// its new views. After it nothing lays the guard out again unless a test does.
    private func addWithItsOneLayout(_ guardView: MacSidebarListSelectionGuardView, to stage: Stage) {
        stage.container.addSubview(guardView)
        stage.window.contentView?.layoutSubtreeIfNeeded()
    }

    private struct TableInWindow {
        let window: NSWindow
        let tableView: StyleRecordingTableView
    }

    /// A table in a scroll view in a window, whose rows each hold a guard. Nothing is laid out
    /// yet: the table makes its rows when the window's views are.
    private func makeTableInWindow(rows: GuardedRows) throws -> TableInWindow {
        let stage = try makeStageInWindow()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let tableView = StyleRecordingTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.width = 280
        tableView.addTableColumn(column)
        tableView.dataSource = rows
        tableView.delegate = rows
        dataSources.append(rows)
        scrollView.documentView = tableView
        stage.container.addSubview(scrollView)
        return TableInWindow(window: stage.window, tableView: tableView)
    }

    /// One turn of the main queue, which is what the guard waits before it writes. Blocks run
    /// in the order they were added, so a turn the guard asked for earlier has run by the time
    /// this returns.
    private func mainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the guard")
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

/// A table that counts the writes of its selection style, whatever they change.
private final class StyleRecordingTableView: NSTableView {
    private(set) var styleWrites = 0

    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { super.selectionHighlightStyle }
        set {
            styleWrites += 1
            super.selectionHighlightStyle = newValue
        }
    }
}

/// A table that does not keep a selection style written to it: it reads as `.regular` after
/// every write. No table measured does this. It stands for a system on which something sets
/// the style back each time.
private final class StyleForgettingTableView: NSTableView {
    private(set) var styleWrites = 0

    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { .regular }
        set { styleWrites += 1 }
    }
}

private final class ThreeRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        3
    }
}

/// Rows that each hold a guard, as a selected row's fill does. The table asks for a row's view
/// while it lays itself out.
@MainActor
private final class GuardedRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let count: Int
    private(set) var guardViews: [MacSidebarListSelectionGuardView] = []

    init(count: Int) {
        self.count = count
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rowContent = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let guardView = MacSidebarListSelectionGuardView()
        rowContent.addSubview(guardView)
        guardViews.append(guardView)
        return rowContent
    }
}
#endif
