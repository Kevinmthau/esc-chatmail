#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The conversation row's trailing swipe as a real list on the Mac builds it: the row actions
/// the table behind a SwiftUI `List` gives for a row with `conversationRowTrailingSwipeActions`.
/// These run in `Mac.xctestplan` only. They show that the swipe, drawn from the policy's actions
/// through a `ForEach`, reaches the table with Archive at the row's edge.
///
/// How the table's array reads: SwiftUI hands AppKit a swipe's buttons in the order they are
/// drawn, left to right. A trailing swipe's array is the declaration reversed, and a leading
/// swipe's is not (`testSwiftUI_givesTheTableEachEdgesButtonsLeftToRight`, measured on macOS
/// 27.2), so the button at the row's edge, the one SwiftUI says a full swipe performs, is a
/// trailing array's last and a leading array's first. AppKit's header does not say which
/// button a full swipe performs, and no swipe was made here.
///
/// HONEST SCOPE: the lists are plain `.inset` `List`s of text rows, not `MacConversationSidebar`,
/// in a window that is never on screen, and the actions are asked of the table's delegate.
/// Nothing is swiped, and no action is performed: `NSTableViewRowAction` keeps its handler to
/// itself, so which closure each runs is pinned from source
/// (`ConversationListSwipeActionsSourceTests`), as is everything about the iPhone's list.
@MainActor
final class ConversationRowTrailingSwipeActionsMacTests: XCTestCase {
    /// Revert-check: swapping the two actions in `ConversationRowSwipePolicy.trailingActions`
    /// makes this fail.
    func testTrailingSwipe_enabled_archiveIsAtTheRowsEdge() throws {
        let tableView = try mountedTableView(ProbeList(isEnabled: true))

        let actions = try rowActions(of: tableView, edge: .trailing)

        XCTAssertEqual(actions.map(\.title), ["Report Spam", "Archive"], "Left to right; the last is at the edge")
        XCTAssertEqual(actions.last?.style, .destructive, "Archive stands for the row's removal")
        XCTAssertEqual(actions.first?.style, .regular, "Report Spam only asks")
    }

    /// Revert-check: making `ConversationRowSwipePolicy.trailingActions` offer anything when
    /// disabled makes this fail.
    func testTrailingSwipe_disabled_tableGivesNoActions() throws {
        let tableView = try mountedTableView(ProbeList(isEnabled: false))

        XCTAssertEqual(try rowActions(of: tableView, edge: .trailing).map(\.title), [])
    }

    /// What the reading above rests on. If this fails, SwiftUI has changed how it hands a
    /// swipe's buttons to the table, and the order asserted for the trailing swipe has to be
    /// read again.
    ///
    /// HONEST SCOPE: there is no production code to revert; this measures SwiftUI.
    func testSwiftUI_givesTheTableEachEdgesButtonsLeftToRight() throws {
        let tableView = try mountedTableView(DeclarationOrderProbeList())

        XCTAssertEqual(try rowActions(of: tableView, edge: .trailing).map(\.title), ["Second", "First"])
        XCTAssertEqual(try rowActions(of: tableView, edge: .leading).map(\.title), ["First", "Second"])
    }

    // MARK: - Helpers

    private struct ProbeList: View {
        let isEnabled: Bool

        var body: some View {
            List {
                ForEach(0..<2, id: \.self) { row in
                    Text("Row \(row)")
                        .conversationRowTrailingSwipeActions(
                            isEnabled: isEnabled,
                            onArchive: {},
                            onReportSpam: {}
                        )
                }
            }
            .listStyle(.inset)
        }
    }

    /// Two plain buttons on each edge, declared "First" then "Second".
    private struct DeclarationOrderProbeList: View {
        var body: some View {
            List {
                ForEach(0..<2, id: \.self) { row in
                    Text("Row \(row)")
                        .swipeActions(edge: .trailing) {
                            Button("First") {}
                            Button("Second") {}
                        }
                        .swipeActions(edge: .leading) {
                            Button("First") {}
                            Button("Second") {}
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    private func mountedTableView(_ list: some View) throws -> NSTableView {
        let host = MacOffscreenHost(
            window: try makeTestHostWindow(),
            size: CGSize(width: 320, height: 200),
            rootView: list
        )
        addTeardownBlock { @MainActor in
            host.close()
        }
        let tableView = try XCTUnwrap(host.waitForView(NSTableView.self), "SwiftUI built no NSTableView for the list")
        let deadline = Date().addingTimeInterval(5)
        while tableView.numberOfRows < 2, Date() < deadline {
            host.settle(for: 0.05)
        }
        XCTAssertGreaterThanOrEqual(tableView.numberOfRows, 2, "The list's rows never reached its table")
        return tableView
    }

    private func rowActions(of tableView: NSTableView, edge: NSTableView.RowActionEdge) throws -> [NSTableViewRowAction] {
        let delegate = try XCTUnwrap(tableView.delegate, "The list's table has no delegate")
        guard delegate.responds(to: #selector(NSTableViewDelegate.tableView(_:rowActionsForRow:edge:))) else {
            XCTFail("The list's table delegate gives no row actions on this system")
            return []
        }
        return delegate.tableView?(tableView, rowActionsForRow: 0, edge: edge) ?? []
    }
}
#endif
