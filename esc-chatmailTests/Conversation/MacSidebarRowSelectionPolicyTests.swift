import XCTest
@testable import esc_chatmail

/// How a row of the Mac sidebar shows that it is selected. The policy is pure and compiles on
/// both platforms, so these run in the iOS suite and in `Mac.xctestplan`.
///
/// HONEST SCOPE: this pins the rule. That `MacConversationSidebar` applies it is pinned from its
/// source (`MacConversationSidebarSourceTests`), and what a Mac list draws under and around the
/// fill was measured off screen, not seen in the app (`MacSidebarRowSelectionPolicy`).
final class MacSidebarRowSelectionPolicyTests: XCTestCase {
    private typealias Policy = MacSidebarRowSelectionPolicy

    /// Revert-check: deleting the `guard isSelected` from `MacSidebarRowSelectionPolicy.fill`
    /// makes this fail: every row of an active window would be drawn selected.
    func testFill_rowNotSelected_isNoneWhateverTheWindow() {
        XCTAssertEqual(Policy.fill(isSelected: false, windowAppearsActive: true), .none)
        XCTAssertEqual(Policy.fill(isSelected: false, windowAppearsActive: false), .none)
    }

    /// The reason the sidebar draws the selection itself: the fill does not ask whether the
    /// list has the keyboard focus, so the open conversation stays colored while the caret is
    /// in the reply field.
    ///
    /// Revert-check: returning `.inactive` for every selected row in
    /// `MacSidebarRowSelectionPolicy.fill` makes this fail.
    func testFill_selectedInAnActiveWindow_isTheAccentColor() {
        XCTAssertEqual(Policy.fill(isSelected: true, windowAppearsActive: true), .accent)
    }

    /// Revert-check: returning `.accent` for every selected row in
    /// `MacSidebarRowSelectionPolicy.fill` makes this fail: a window behind another app would
    /// keep a colored selection, which no Mac list does.
    func testFill_selectedInAnInactiveWindow_isGray() {
        XCTAssertEqual(Policy.fill(isSelected: true, windowAppearsActive: false), .inactive)
    }

    /// Revert-check: returning `.standard` from `MacSidebarRowSelectionPolicy.palette(on:)` for
    /// `.accent` makes this fail: dark text on the accent color.
    func testPalette_onTheAccentFill_isLight() {
        XCTAssertEqual(Policy.palette(on: .accent), .onSelectionFill)
    }

    /// The inactive gray is light in a light window and dark in a dark one, like the list's
    /// background, so white text on it could not be read in a light window.
    ///
    /// Revert-check: returning `.onSelectionFill` from
    /// `MacSidebarRowSelectionPolicy.palette(on:)` for `.inactive` makes this fail.
    func testPalette_onTheInactiveFillOrNone_isStandard() {
        XCTAssertEqual(Policy.palette(on: .inactive), .standard)
        XCTAssertEqual(Policy.palette(on: .none), .standard)
    }

    // MARK: - Joins

    /// One selected row is the open chat, and nearly always the whole selection: its fill is
    /// rounded at all four corners, and finding that out costs nothing. The sidebar asks at
    /// every evaluation of its body, with every row it has loaded.
    ///
    /// Revert-check: deleting `guard selection.count > 1 else { return [:] }` from
    /// `MacSidebarRowSelectionPolicy.joins` makes this fail: the answers stay empty, but every
    /// row is walked to reach them.
    func testJoins_oneRowSelectedOrNone_isEmptyAndWalksNoRow() {
        let oneSelected = WalkedRows(["a", "b", "c"])
        XCTAssertEqual(Policy.joins(orderedIDs: oneSelected, selection: ["b"]), [:])
        XCTAssertEqual(oneSelected.walked, 0)

        let noneSelected = WalkedRows(["a", "b", "c"])
        XCTAssertEqual(Policy.joins(orderedIDs: noneSelected, selection: Set<String>()), [:])
        XCTAssertEqual(noneSelected.walked, 0)
    }

    /// The list draws selected rows that touch as one shape, so each fill is square where it
    /// meets the next.
    ///
    /// Revert-check: returning `[:]` from `MacSidebarRowSelectionPolicy.joins` makes this fail:
    /// the list's own selection would show at the corners between the rows.
    func testJoins_rowsThatTouch_joinEachOther() {
        let joins = Policy.joins(orderedIDs: ["a", "b", "c", "d", "e"], selection: ["b", "c", "d"])

        XCTAssertEqual(
            joins,
            [
                "b": Policy.Joins(above: false, below: true),
                "c": Policy.Joins(above: true, below: true),
                "d": Policy.Joins(above: true, below: false)
            ]
        )
    }

    /// Revert-check: deleting `previousSelectedID = nil` from the unselected branch of
    /// `MacSidebarRowSelectionPolicy.joins` makes this fail: rows with an unselected row
    /// between them would be drawn as if they touched.
    func testJoins_selectedRowsApart_joinNothing() {
        XCTAssertEqual(Policy.joins(orderedIDs: ["a", "b", "c", "d", "e"], selection: ["a", "c", "e"]), [:])
    }

    /// The rows a user selects are near the ones on screen, and the list can hold thousands
    /// below them, so the walk ends at the last selected row.
    ///
    /// Revert-check: deleting `if selectedRowsNotYetMet == 0 { break }` from
    /// `MacSidebarRowSelectionPolicy.joins` makes this fail: all six rows are walked.
    func testJoins_stopsWalkingAtTheLastSelectedRow() {
        let rows = WalkedRows(["a", "b", "c", "d", "e", "f"])

        let joins = Policy.joins(orderedIDs: rows, selection: ["b", "c"])

        XCTAssertEqual(
            joins,
            [
                "b": Policy.Joins(above: false, below: true),
                "c": Policy.Joins(above: true, below: false)
            ]
        )
        XCTAssertEqual(rows.walked, 3, "a, b and c: nothing below the last selected row")
    }

    /// A selected conversation whose row a search or a filter hides stays selected
    /// (`MacSidebarSelectionPolicy`), and is no row's neighbor. The walk never meets it, so it
    /// cannot stop early, and the rows that are showing still get their joins.
    ///
    /// HONEST SCOPE: no line of `joins` is there for this case, so no one change to it fails
    /// this test alone. It records what the walk does with a selected row it never meets.
    func testJoins_selectedRowNotInTheList_joinsNothingAndHidesNoJoin() {
        XCTAssertEqual(Policy.joins(orderedIDs: ["a", "b", "c"], selection: ["b", "hidden"]), [:])

        let rows = WalkedRows(["a", "b", "c", "d"])
        let joins = Policy.joins(orderedIDs: rows, selection: ["a", "b", "hidden"])

        XCTAssertEqual(
            joins,
            [
                "a": Policy.Joins(above: false, below: true),
                "b": Policy.Joins(above: true, below: false)
            ]
        )
        XCTAssertEqual(rows.walked, 4, "the hidden row might have been below any of them")
    }
}

/// A list's rows that count how many of them a walk has taken.
private final class WalkedRows: Sequence {
    private let ids: [String]
    private(set) var walked = 0

    init(_ ids: [String]) {
        self.ids = ids
    }

    func makeIterator() -> AnyIterator<String> {
        var next = ids.startIndex
        return AnyIterator {
            guard next < self.ids.endIndex else { return nil }
            defer {
                next += 1
                self.walked += 1
            }
            return self.ids[next]
        }
    }
}
