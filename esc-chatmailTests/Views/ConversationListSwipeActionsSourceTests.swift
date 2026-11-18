import XCTest

/// Pins the conversation list's trailing swipe: a full swipe archives, and Report Spam is
/// offered only by a partial swipe, behind Archive.
///
/// SwiftUI performs a full swipe with the first button of a `swipeActions` block, the one
/// drawn at the row's edge, so the order of the buttons in the source is the behavior. No
/// test can perform a swipe, so the order is read from source, for the iPhone's list and the
/// Mac's sidebar alike.
final class ConversationListSwipeActionsSourceTests: XCTestCase {
    // Revert-check: swapping the Archive and Spam buttons in either file's trailing
    // `swipeActions` fails the order assertion; removing the Spam button fails the
    // presence assertion.
    func testTrailingSwipe_iOSList_fullSwipeArchivesAndPartialSwipeOffersSpam() throws {
        let source = try repositorySource("esc-chatmail/Views/Main/ConversationListView.swift")
        try assertTrailingSwipe(
            in: try trailingSwipeSource(of: source),
            archiveCall: "viewModel.archiveConversation(withID: item.id)",
            spamCall: "viewModel.reportSpamConversations(withIDs: [item.id])"
        )
    }

    func testTrailingSwipe_macSidebar_fullSwipeArchivesAndPartialSwipeOffersSpam() throws {
        let source = try repositorySource("esc-chatmail/Platform/MacConversationSidebar.swift")
        try assertTrailingSwipe(
            in: try trailingSwipeSource(of: source),
            archiveCall: "onArchive([item.id])",
            spamCall: "onReportSpam([item.id])"
        )
    }

    // MARK: - Helpers

    private func assertTrailingSwipe(
        in block: String,
        archiveCall: String,
        spamCall: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let archive = try XCTUnwrap(
            block.range(of: archiveCall),
            "The trailing swipe no longer archives",
            file: file,
            line: line
        )
        let spam = try XCTUnwrap(
            block.range(of: spamCall),
            "The trailing swipe no longer offers Report Spam",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            archive.lowerBound,
            spam.lowerBound,
            "Archive must be the trailing swipe's first button: a full swipe performs the first",
            file: file,
            line: line
        )
        XCTAssertEqual(
            block.components(separatedBy: "Button(").count - 1,
            2,
            "The trailing swipe should hold exactly Archive and Spam",
            file: file,
            line: line
        )
    }

    /// The text of the trailing `swipeActions` block, up to the leading one that follows it.
    private func trailingSwipeSource(of source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: ".swipeActions(edge: .trailing, allowsFullSwipe: true)"),
            "The list has no full-swipe trailing swipe action"
        )
        let end = try XCTUnwrap(
            source.range(of: ".swipeActions(edge: .leading", range: start.upperBound..<source.endIndex),
            "The list's trailing swipe is no longer followed by its leading one"
        )
        return String(source[start.upperBound..<end.lowerBound])
    }
}
