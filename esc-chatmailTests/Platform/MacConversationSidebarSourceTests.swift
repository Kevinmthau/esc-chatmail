import XCTest
@testable import esc_chatmail

/// What the Mac sidebar gives each conversation row, read from `MacConversationSidebar`'s
/// source.
///
/// The selected row's fill and its colors are two modifiers that have to come from one decision
/// (`MacSidebarRowSelectionPolicy`). Drop the fill and the row's white text sits on the list's
/// own gray selection whenever the caret is in the reply field; drop the palette and dark text
/// sits on the accent color. Neither is a compile error, and no policy test would notice.
///
/// The same goes for what the fill is decided from. The window's active state and the joins of
/// selected rows that touch are each one argument, and a constant in its place compiles and
/// passes every policy test.
///
/// HONEST SCOPE: this reads source text, as `MacMailboxViewSourceTests` does, so it runs in the
/// iOS suite although the view is Mac-only. It pins that the row takes the Mac's metrics, that
/// the palette and the fill are both built from `selectionFill`, that the fill is decided from
/// the window's active state and given its joins, and that the filter button is given the words
/// for its badge. It matches the spelling of the source, so renaming a local fails it too. What
/// the list then draws was measured off screen, not seen in the app.
final class MacConversationSidebarSourceTests: XCTestCase {
    /// Revert-check: passing `metrics: .iOS` to the row in `MacConversationSidebar.body` makes
    /// this fail: the sidebar would show the iPhone's row, chevron and all.
    func testRow_takesTheMacMetrics() throws {
        let row = try rowSource()

        XCTAssertTrue(row.contains("metrics: .mac"), row)
    }

    /// Revert-check: deleting the row's `.listRowBackground(...)` from
    /// `MacConversationSidebar.body` makes this fail.
    func testRow_drawsTheFillItsPaletteWasChosenFor() throws {
        let row = try rowSource()

        XCTAssertTrue(
            row.contains("palette: MacSidebarRowSelectionPolicy.palette(on: selectionFill)"),
            row
        )
        XCTAssertTrue(row.contains(".listRowBackground("), row)
        XCTAssertTrue(row.contains("MacSidebarRowSelectionBackground("), row)
        XCTAssertTrue(row.contains("fill: selectionFill,"), row)
    }

    /// A selected row is gray in a window the user is not working in, as in every Mac list.
    /// The window's state reaches the row from the environment (`appearsActive`).
    ///
    /// Revert-check: passing `windowAppearsActive: true` to `MacSidebarRowSelectionPolicy.fill`
    /// in `MacConversationSidebar.body` makes this fail: the open conversation would stay in
    /// the accent color behind other apps.
    func testRow_fillFollowsTheWindowsActiveState() throws {
        let row = try rowSource()

        XCTAssertTrue(row.contains("windowAppearsActive: appearsActive"), row)
        XCTAssertTrue(
            try sidebarSource().contains(#"@Environment(\.appearsActive) private var appearsActive"#)
        )
    }

    /// Selected rows that touch are one shape, so each fill is square where it meets the next
    /// (`MacSidebarRowSelectionPolicy.joins`).
    ///
    /// Revert-check: passing `joins: .none` to `MacSidebarRowSelectionBackground` in
    /// `MacConversationSidebar.body` makes this fail: every fill would be rounded at all four
    /// corners.
    func testRow_fillIsGivenTheJoinsOfTheListsRowsAndTheSelection() throws {
        let row = try rowSource()
        let source = try sidebarSource()
        let joinsStart = try XCTUnwrap(
            source.range(of: "let selectionJoins = MacSidebarRowSelectionPolicy.joins("),
            "MacConversationSidebar no longer computes its rows' joins the way this test reads them"
        )
        let joinsEnd = try XCTUnwrap(
            source.range(of: "List(selection:", range: joinsStart.upperBound..<source.endIndex)
        )
        let joinsCall = String(source[joinsStart.lowerBound..<joinsEnd.lowerBound])

        XCTAssertTrue(row.contains("joins: selectionJoins[item.id] ?? .none"), row)
        XCTAssertTrue(joinsCall.contains("orderedIDs: viewModel.filteredConversationItems.lazy.map(\\.id)"), joinsCall)
        XCTAssertTrue(joinsCall.contains("selection: selection"), joinsCall)
    }

    /// The filter button's badge is a bare number, so the button is also given the words for
    /// it (`MacSidebarFilterBadgePolicy`).
    ///
    /// Revert-check: deleting the `.accessibilityValue(...)` or the `.help(...)` after the
    /// filter menu's `.badge(...)` in `MacConversationSidebar.body` makes this fail.
    func testFilterButton_isGivenTheWordsForItsBadge() throws {
        let source = try sidebarSource()
        let badge = try XCTUnwrap(
            source.range(of: ".badge(MacSidebarFilterBadgePolicy.badgeCount(for: viewModel.currentFilter))"),
            "MacConversationSidebar no longer badges its filter menu the way this test reads it"
        )
        let end = try XCTUnwrap(source.range(of: ".focusedSceneValue(", range: badge.upperBound..<source.endIndex))
        let afterBadge = String(source[badge.upperBound..<end.lowerBound])

        XCTAssertTrue(
            afterBadge.contains(
                ".accessibilityValue(MacSidebarFilterBadgePolicy.spokenValue(for: viewModel.currentFilter))"
            ),
            afterBadge
        )
        XCTAssertTrue(
            afterBadge.contains(".help(MacSidebarFilterBadgePolicy.helpText(for: viewModel.currentFilter))"),
            afterBadge
        )
    }

    private func sidebarSource() throws -> String {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("esc-chatmail/Platform/MacConversationSidebar.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// The source of one conversation row: from the `ForEach` over the list's items to the
    /// row's first swipe action.
    private func rowSource() throws -> String {
        let source = try sidebarSource()

        let start = try XCTUnwrap(
            source.range(of: "ForEach(viewModel.filteredConversationItems) { item in"),
            "MacConversationSidebar no longer lists its rows the way this test reads them"
        )
        let end = try XCTUnwrap(
            source.range(of: ".swipeActions(", range: start.upperBound..<source.endIndex),
            "The sidebar's row has no swipe action this test can stop at"
        )
        return String(source[start.upperBound..<end.lowerBound])
    }
}
