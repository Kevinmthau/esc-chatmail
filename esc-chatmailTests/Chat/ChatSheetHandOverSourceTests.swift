import XCTest
@testable import esc_chatmail

/// Pins, from the source text, that `ChatView` hears of a sheet handed to another destination.
///
/// The Mac gives an open sheet's window to the next destination (Participants, then New
/// Contact) with no `onDismiss` and without running an `onAppear` on the content again.
/// `ChatView` tracked the sheet on screen by such an `onAppear` alone, so it refused every
/// dismissal of the New Contact sheet as the end of a sheet being replaced, and nothing closed
/// it (build 562, 2026-11-15). `appSheet(item:)`'s `onItemShown` is what tells it now, through
/// `View.onSheetItemShown(_:perform:)`.
///
/// HONEST SCOPE: this reads the three files' text, because no test presents a sheet and CI runs
/// no Mac test. It cannot tell what the Mac's sheet does: that was measured
/// (`View.onMacSheetItemHandOver`). `MacSheetItemHandOverTests` runs the helper, in the Mac
/// plan for the Mac's half, and `ChatSheetDismissalPolicyTests` runs the rule the record feeds.
final class ChatSheetHandOverSourceTests: XCTestCase {
    /// Revert-check: deleting the `onItemShown: { presentedSheetDestination = $0 }` argument
    /// from the `appSheet` call in `ChatView.content` makes this fail.
    func testChatView_sheet_recordsTheDestinationOnScreenFromOnItemShown() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/ChatView.swift")
        let argument = try XCTUnwrap(
            source.range(of: "onItemShown: {"),
            "ChatView's sheet no longer hears which destination is on screen"
        )
        let action = source[argument.upperBound...]
        let end = try XCTUnwrap(action.range(of: "}"))
        XCTAssertTrue(
            action[..<end.lowerBound].contains("presentedSheetDestination = $0"),
            "onItemShown must record the destination now on screen"
        )
    }

    /// The record has one writer besides the dismissal that clears it. A second one on the
    /// sheet's content, in an `onAppear`, is the fault itself: it looks right on iOS and is
    /// silent when the Mac hands the window over.
    ///
    /// Revert-check: adding `.onAppear { presentedSheetDestination = destination }` to
    /// `destinationSheet(destination)` in the sheet's content in `ChatView.content` makes this
    /// fail.
    func testChatView_presentedSheetDestination_isWrittenOnlyByOnItemShownAndTheDismissal() throws {
        let writes = Self.codeLines(try repositorySource("esc-chatmail/Views/Chat/ChatView.swift"))
            .filter { $0.contains("presentedSheetDestination = ") }
        XCTAssertEqual(
            writes,
            ["onItemShown: { presentedSheetDestination = $0 }", "presentedSheetDestination = nil"]
        )
    }

    /// Revert-check: deleting `.onSheetItemShown(item.id) { onItemShown?(item) }` from
    /// `View.appSheet(item:mac:onDismiss:onItemShown:content:)` makes this fail.
    func testAppSheet_itemForm_reportsEachItemShownOnItsContent() throws {
        let code = Self.codeLines(try repositorySource("esc-chatmail/Platform/View+AppSheet.swift"))
        let content = try XCTUnwrap(code.firstIndex(of: "content(item)"))
        XCTAssertEqual(
            Array(code[content...].prefix(3)),
            [
                "content(item)",
                ".onSheetItemShown(item.id) { onItemShown?(item) }",
                ".macSheetChrome(chrome(item))"
            ]
        )
    }

    /// CI compiles the Mac build but runs no Mac test, so both halves of the report are pinned
    /// here too: the appearance, and the Mac's hand-over after it.
    ///
    /// Revert-check: deleting `.onMacSheetItemHandOver(to: id, perform: action)` from
    /// `View.onSheetItemShown(_:perform:)` makes this fail.
    func testOnSheetItemShown_reportsTheAppearanceThenTheMacsHandOver() throws {
        let code = Self.codeLines(try repositorySource(Self.helperPath))
        let appearance = try XCTUnwrap(code.firstIndex(of: "onAppear(perform: action)"))
        XCTAssertEqual(
            Array(code[appearance...].prefix(2)),
            ["onAppear(perform: action)", ".onMacSheetItemHandOver(to: id, perform: action)"]
        )
    }

    /// Revert-check: replacing `onChange(of: id) { action() }` with `self` in
    /// `View.onMacSheetItemHandOver(to:perform:)` makes this fail.
    func testOnMacSheetItemHandOver_macBranch_watchesTheItem() throws {
        let code = Self.codeLines(try repositorySource(Self.helperPath))
        let macBranch = try XCTUnwrap(code.firstIndex(of: "#if os(macOS)"))
        let otherBranch = try XCTUnwrap(code.firstIndex(of: "#else"))
        XCTAssertLessThan(macBranch, otherBranch)
        XCTAssertEqual(Array(code[(macBranch + 1)..<otherBranch]), ["onChange(of: id) { action() }"])
    }

    private static let helperPath = "esc-chatmail/Platform/View+MacSheetItemHandOver.swift"

    /// The lines of `source` that are code, trimmed: no comment lines and no blank ones.
    private static func codeLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
    }
}
