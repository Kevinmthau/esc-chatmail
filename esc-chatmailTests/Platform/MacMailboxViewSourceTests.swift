import XCTest
@testable import esc_chatmail

/// The modifiers on the Mac mailbox's sidebar column, read from `MacMailboxView`'s source.
///
/// Two things about them fail silently, with nothing a compiler or a unit test of a policy would
/// notice:
/// - `navigationSplitViewColumnWidth` has to be the column's last modifier. With
///   `toolbar(removing:)` applied after it the width was ignored, and the sidebar came up 144
///   points wide with a 140-point minimum.
/// - Without `macSplitViewColumnCannotCollapse()` a drag of the divider closes the sidebar.
///
/// HONEST SCOPE: this reads source text, as `AppSheetSourceTests` does, so it runs in the iOS
/// suite although the view is Mac-only. It pins which modifiers the column has and their order.
/// What SwiftUI does with that order was measured in a throwaway program on macOS 27.2, not in
/// the app (`MacMailboxView`, `MacSidebarCollapseGuardView`). It matches the spelling and the
/// layout of the source, so reformatting the column's modifiers can fail it too.
final class MacMailboxViewSourceTests: XCTestCase {
    /// Revert-check: moving `.toolbar(removing: .sidebarToggle)` below
    /// `.navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)` in `MacMailboxView.body`
    /// makes this fail.
    func testSidebarColumn_columnWidth_isItsLastModifier() throws {
        let modifiers = try sidebarColumnModifiers()

        XCTAssertEqual(
            modifiers.last,
            ".navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)",
            "A modifier applied after the column width makes the split view ignore it: \(modifiers)"
        )
    }

    /// Revert-check: deleting `.macSplitViewColumnCannotCollapse()` from `MacMailboxView.body`
    /// makes this fail.
    func testSidebarColumn_appliesTheCollapseGuard() throws {
        let modifiers = try sidebarColumnModifiers()

        XCTAssertTrue(
            modifiers.contains(".macSplitViewColumnCannotCollapse()"),
            "Without the guard a drag of the divider closes the sidebar: \(modifiers)"
        )
    }

    /// The modifiers applied to the sidebar column's content, in order: the lines between the
    /// split view's opening and its `detail:` closure that start with a period at the
    /// indentation of the content itself. Its arguments and the comments are indented deeper or
    /// do not start with a period.
    private func sidebarColumnModifiers() throws -> [String] {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("esc-chatmail/Platform/MacMailboxView.swift")
        let lines = try String(contentsOf: sourceURL, encoding: .utf8).components(separatedBy: "\n")

        let opening = try XCTUnwrap(
            lines.firstIndex { $0.contains("NavigationSplitView(columnVisibility: $columnVisibility) {") },
            "MacMailboxView no longer opens its split view the way this test reads it"
        )
        let detail = try XCTUnwrap(
            lines[opening...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "} detail: {" },
            "MacMailboxView's split view has no detail closure this test can find"
        )
        let column = lines[(opening + 1)..<detail]
        let content = try XCTUnwrap(
            column.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("MacConversationSidebar(") },
            "The sidebar column's content is no longer MacConversationSidebar"
        )
        let contentIndentation = content.prefix { $0 == " " }.count

        return column
            .filter { $0.prefix { $0 == " " }.count == contentIndentation }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".") }
    }
}
