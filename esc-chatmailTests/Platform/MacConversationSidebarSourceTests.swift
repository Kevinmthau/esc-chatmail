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
/// HONEST SCOPE: this reads source text, as `MacMailboxViewSourceTests` does, so it runs in the
/// iOS suite although the view is Mac-only. It pins that the row takes the Mac's metrics and
/// that the palette and the fill are both built from `selectionFill`. It matches the spelling of
/// the source, so renaming that local fails it too. What the list then draws was measured off
/// screen, not seen in the app.
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

    /// The source of one conversation row: from the `ForEach` over the list's items to the
    /// row's first swipe action.
    private func rowSource() throws -> String {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("esc-chatmail/Platform/MacConversationSidebar.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

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
