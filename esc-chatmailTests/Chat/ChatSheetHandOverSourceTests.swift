import XCTest
@testable import esc_chatmail

/// Pins, from the source text, that `ChatView` hears of a sheet handed to another destination.
///
/// The Mac gives an open sheet's window to the next destination (Participants, then New
/// Contact) with no `onDismiss` and without running the content's `onAppear` again. `ChatView`
/// tracked the sheet on screen by that `onAppear` alone, so it refused every dismissal of the
/// New Contact sheet as the end of a sheet being replaced, and nothing closed it (build 562,
/// 2026-11-15). `View.onMacSheetItemHandOver(to:perform:)` is what tells it.
///
/// HONEST SCOPE: this reads the two files' text, because no test presents a sheet and CI runs
/// no Mac test. It cannot tell what the Mac's sheet does: that was measured
/// (`View.onMacSheetItemHandOver`). `MacSheetItemHandOverTests` runs the helper, in the Mac
/// plan for the Mac's half.
final class ChatSheetHandOverSourceTests: XCTestCase {
    /// Revert-check: deleting the `.onMacSheetItemHandOver(to: destination.id) { … }` call from
    /// the sheet's content in `ChatView.body` makes this fail.
    func testChatView_sheetContent_recordsTheDestinationHandedTheSheet() throws {
        let source = try appSource("Views/Chat/ChatView.swift")
        let call = try XCTUnwrap(
            source.range(of: ".onMacSheetItemHandOver(to: destination.id) {"),
            "ChatView's sheet content no longer hears of a hand-over"
        )
        let action = source[call.upperBound...]
        let end = try XCTUnwrap(action.range(of: "}"))
        XCTAssertTrue(
            action[..<end.lowerBound].contains("presentedSheetDestination = destination"),
            "The hand-over must record the destination now on screen"
        )
    }

    /// CI compiles the Mac build but runs no Mac test, so the Mac branch is pinned here too.
    ///
    /// Revert-check: replacing `onChange(of: id) { action() }` with `self` in
    /// `View.onMacSheetItemHandOver(to:perform:)` makes this fail.
    func testOnMacSheetItemHandOver_macBranch_watchesTheItem() throws {
        let source = try appSource("Platform/View+MacSheetItemHandOver.swift")
        let code = source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        let macBranch = try XCTUnwrap(code.firstIndex(of: "#if os(macOS)"))
        let otherBranch = try XCTUnwrap(code.firstIndex(of: "#else"))
        XCTAssertLessThan(macBranch, otherBranch)
        XCTAssertEqual(Array(code[(macBranch + 1)..<otherBranch]), ["onChange(of: id) { action() }"])
    }

    private func appSource(_ path: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Chat
            .deletingLastPathComponent() // esc-chatmailTests
            .deletingLastPathComponent() // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent("esc-chatmail").appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
