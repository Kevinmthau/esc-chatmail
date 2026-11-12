#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The fill behind a selected row of the Mac sidebar. These run in `Mac.xctestplan` only: the
/// view is Mac-only.
///
/// The two list tests mount a real SwiftUI `List`, off screen, and look for the `NSTableView`
/// behind it. They are what pins that the guard in the fill reaches the list it is drawn in.
/// The list here has the fill and nothing behind it, so the fill's guard is the one that turns
/// the selection off, a turn of the main queue after the row is selected. The sidebar's list
/// also has a guard behind it, which does it before any row is selected:
/// `MacConversationSidebarSelectionGuardTests` mounts that.
///
/// HONEST SCOPE: the list is a plain `.inset` `List(selection:)` with the sidebar's row
/// background, not `MacConversationSidebar`, in a window that is never on screen. These pin
/// that the list stops drawing its own selection on the system the tests run on. They do not
/// draw anything: what the fill looks like, and that nothing of the list's selection shows
/// around it, was measured off screen and has not been seen in the app
/// (`MacSidebarListSelectionGuardView`).
@MainActor
final class MacSidebarRowSelectionBackgroundTests: XCTestCase {
    /// Most rows of the sidebar are not selected, and they get no view of the sidebar's.
    ///
    /// Revert-check: returning a clear fill for `.none` from
    /// `MacSidebarRowSelectionBackground.init` in place of nil makes this fail.
    func testBackground_forARowThatIsNotSelected_isNoView() {
        XCTAssertNil(MacSidebarRowSelectionBackground(fill: .none, joins: .none))
        XCTAssertNil(
            MacSidebarRowSelectionBackground(fill: .none, joins: .init(above: true, below: true))
        )
    }

    func testBackground_forASelectedRow_isAView() {
        XCTAssertNotNil(MacSidebarRowSelectionBackground(fill: .accent, joins: .none))
        XCTAssertNotNil(MacSidebarRowSelectionBackground(fill: .inactive, joins: .none))
    }

    /// The reason the guard exists: left alone, the table behind a list draws a selection of
    /// its own. If this fails, a system has stopped doing that, and the guard has nothing left
    /// to turn off.
    func testList_withNoFill_drawsItsOwnSelection() async throws {
        let tableView = try await tableViewOfMountedList(selectedRowHasFill: false)

        XCTAssertEqual(tableView.selectionHighlightStyle, .regular)
    }

    /// Revert-check: deleting the `.background { MacSidebarListSelectionGuard()… }` from
    /// `MacSidebarRowSelectionBackground.body` makes this fail: the list's own selection is
    /// drawn under the fill again.
    func testList_withTheFillBehindItsSelectedRow_stopsDrawingItsOwnSelection() async throws {
        let tableView = try await tableViewOfMountedList(selectedRowHasFill: true)

        try await waitUntil { tableView.selectionHighlightStyle == .none }

        XCTAssertEqual(tableView.selectionHighlightStyle, .none)
        XCTAssertEqual(tableView.selectedRowIndexes, [1], "the row is still selected")
    }

    // MARK: - Helpers

    private struct ProbeList: View {
        let selectedRowHasFill: Bool
        @State private var selection: Set<Int> = [1]

        var body: some View {
            List(selection: $selection) {
                ForEach(0..<4, id: \.self) { row in
                    Text("Row \(row)")
                        .listRowBackground(
                            selectedRowHasFill
                                ? MacSidebarRowSelectionBackground(
                                    fill: MacSidebarRowSelectionPolicy.fill(
                                        isSelected: selection.contains(row),
                                        windowAppearsActive: true
                                    ),
                                    joins: .none
                                )
                                : nil
                        )
                }
            }
            .listStyle(.inset)
            .frame(width: 320, height: 300)
        }
    }

    /// Mounts the list and returns the table behind it, once SwiftUI has built it and the
    /// selection has reached it.
    private func tableViewOfMountedList(selectedRowHasFill: Bool) async throws -> NSTableView {
        let host = try mountInTestWindow(ProbeList(selectedRowHasFill: selectedRowHasFill))

        var found: NSTableView?
        try await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            found = Self.tableView(in: host.view)
            return found?.selectedRowIndexes == [1]
        }
        return try XCTUnwrap(found, "SwiftUI built no NSTableView for the list")
    }

    private static func tableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView {
            return tableView
        }
        for subview in view.subviews {
            if let tableView = tableView(in: subview) {
                return tableView
            }
        }
        return nil
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the list")
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
#endif
