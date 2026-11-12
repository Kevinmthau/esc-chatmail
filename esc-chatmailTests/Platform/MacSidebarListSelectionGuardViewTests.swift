#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// The view that stops a list drawing its own selection under the Mac sidebar's fill. These run
/// in `Mac.xctestplan` only: the view is AppKit.
///
/// HONEST SCOPE: the table here is AppKit's own, built by hand. That pins what the guard does to
/// an `NSTableView` it is inside. That SwiftUI's `List` is such a table, with a row's background
/// inside it, is pinned by `MacSidebarRowSelectionBackgroundTests`, which mounts a real list.
/// What a table with the style `.none` then draws was measured in a throwaway program, not seen
/// in the app (`MacSidebarListSelectionGuardView`).
@MainActor
final class MacSidebarListSelectionGuardViewTests: XCTestCase {
    /// Revert-check: deleting `tableView.selectionHighlightStyle = .none` from
    /// `MacSidebarListSelectionGuardView.guardEnclosingTableView` makes this fail.
    func testGuard_insideATablesRow_turnsOffTheTablesOwnSelection() {
        let table = makeTable()
        XCTAssertEqual(table.tableView.selectionHighlightStyle, .regular, "a table draws its selection")
        let guardView = MacSidebarListSelectionGuardView()

        table.rowContent.addSubview(guardView)

        XCTAssertTrue(guardView.guardedTableView === table.tableView)
        XCTAssertEqual(table.tableView.selectionHighlightStyle, .none)
    }

    /// SwiftUI did not set the style back in the measurements. If something does, the next
    /// layout of a selected row's fill turns it off again.
    ///
    /// Revert-check: deleting `guardEnclosingTableView()` from
    /// `MacSidebarListSelectionGuardView.layout` makes this fail.
    func testGuard_styleSetBack_isTurnedOffAgainAtTheNextLayout() {
        let table = makeTable()
        let guardView = MacSidebarListSelectionGuardView()
        table.rowContent.addSubview(guardView)

        table.tableView.selectionHighlightStyle = .regular
        guardView.layout()

        XCTAssertEqual(table.tableView.selectionHighlightStyle, .none)
    }

    /// The table is the one the guard is inside, however far up. In a SwiftUI list it was four
    /// superviews up.
    ///
    /// Revert-check: returning `superview as? NSTableView` from
    /// `MacSidebarListSelectionGuardView.enclosingTableView` makes this fail.
    func testGuard_severalViewsDeepInATable_stillFindsIt() {
        let table = makeTable()
        let inner = NSView()
        let innermost = NSView()
        table.rowContent.addSubview(inner)
        inner.addSubview(innermost)
        let guardView = MacSidebarListSelectionGuardView()

        innermost.addSubview(guardView)

        XCTAssertTrue(guardView.guardedTableView === table.tableView)
        XCTAssertEqual(table.tableView.selectionHighlightStyle, .none)
    }

    func testGuard_outsideATable_guardsNothing() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let guardView = MacSidebarListSelectionGuardView()

        container.addSubview(guardView)
        guardView.guardEnclosingTableView()

        XCTAssertNil(guardView.guardedTableView)
    }

    /// The style changes what the table draws, not what it selects: the selection the sidebar
    /// reads is still the table's.
    func testGuard_leavesTheTablesSelectionAlone() {
        let table = makeTable()
        table.tableView.selectRowIndexes([1], byExtendingSelection: false)
        let guardView = MacSidebarListSelectionGuardView()

        table.rowContent.addSubview(guardView)

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

    // MARK: - Helpers

    private var dataSources: [ThreeRows] = []

    override func tearDown() {
        dataSources = []
        super.tearDown()
    }

    private struct Table {
        let tableView: NSTableView
        /// A view inside the table, standing for a row's content.
        let rowContent: NSView
    }

    private func makeTable() -> Table {
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        let dataSource = ThreeRows()
        tableView.dataSource = dataSource
        // The table holds its data source weakly.
        dataSources.append(dataSource)
        tableView.reloadData()
        let rowContent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tableView.addSubview(rowContent)
        return Table(tableView: tableView, rowContent: rowContent)
    }
}

private final class ThreeRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        3
    }
}
#endif
