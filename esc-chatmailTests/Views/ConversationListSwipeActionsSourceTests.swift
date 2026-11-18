import XCTest

/// Pins the conversation rows' trailing swipe, one definition the iPhone's list and the Mac's
/// sidebar share (`View.conversationRowTrailingSwipeActions`): a full swipe archives, Report Spam
/// is offered only by a partial swipe, behind Archive, and it asks before it reports
/// (`View.conversationSpamConfirmation`).
///
/// SwiftUI performs a full swipe with the first button of a `swipeActions` block, the one drawn
/// at the row's edge, so the order of the buttons in the source is the behavior. No test can
/// perform a swipe, so all of it is read from source.
///
/// HONEST SCOPE: nothing here swipes a row or presents the question. Neither the swipe nor the
/// question has been seen in the app, on the iPhone or the Mac.
final class ConversationListSwipeActionsSourceTests: XCTestCase {
    private static let sharedSwipePath = "esc-chatmail/Views/Main/View+ConversationRowSwipeActions.swift"
    private static let iOSListPath = "esc-chatmail/Views/Main/ConversationListView.swift"
    private static let macSidebarPath = "esc-chatmail/Platform/MacConversationSidebar.swift"

    /// Revert-check: swapping the two buttons in `View.conversationRowTrailingSwipeActions`
    /// fails the order assertion; adding a third button there, written `Button(` or
    /// `Button {`, fails the count.
    func testSharedTrailingSwipe_fullSwipe_archivesAndPartialSwipeOffersReportSpam() throws {
        let buttons = try sharedSwipeButtons()

        XCTAssertEqual(buttons.count, 2, "The trailing swipe should hold exactly Archive and Report Spam")
        guard buttons.count == 2 else { return }
        XCTAssertTrue(
            buttons[0].contains("onArchive()") && buttons[0].contains(#"SwiftUI.Label("Archive""#),
            "Archive must be the trailing swipe's first button: a full swipe performs the first\n\(buttons[0])"
        )
        XCTAssertTrue(
            buttons[1].contains("onReportSpam()") && buttons[1].contains(#"SwiftUI.Label("Report Spam""#),
            "Report Spam must be the trailing swipe's second button, named as the menus name it\n\(buttons[1])"
        )
    }

    /// Revert-check: giving the Report Spam button in `View.conversationRowTrailingSwipeActions`
    /// `role: .destructive` fails this; so does a `conversationSpamConfirmation` whose answer
    /// no longer calls `onConfirm`.
    func testSharedTrailingSwipe_reportSpam_onlyAsksAndTheAnswerReports() throws {
        let buttons = try sharedSwipeButtons()
        let reportSpam = try XCTUnwrap(buttons.last, "The trailing swipe has no buttons")
        XCTAssertFalse(
            reportSpam.contains("role:"),
            "A destructive swipe button stands for the row's removal, before the question is answered\n\(reportSpam)"
        )

        let source = try repositorySource(Self.sharedSwipePath)
        let question = try delimitedBody(
            after: "confirmationDialog(",
            open: "(",
            close: ")",
            in: source,
            path: Self.sharedSwipePath,
            openingIsInMarker: true
        )
        // The answer that reports is the closure after the dialog's arguments: its actions.
        let actions = try delimitedBody(
            after: "{ pendingConversationID in",
            open: "{",
            close: "}",
            in: source,
            path: Self.sharedSwipePath,
            openingIsInMarker: true
        )
        XCTAssertTrue(question.contains("presenting: conversationID.wrappedValue"), question)
        XCTAssertTrue(actions.contains(#"Button("Report Spam", role: .destructive)"#), actions)
        XCTAssertTrue(actions.contains("onConfirm(pendingConversationID)"), actions)
        XCTAssertTrue(actions.contains(#"Button("Cancel", role: .cancel)"#), actions)
    }

    /// Revert-check: moving the Report Spam button out of `if isEnabled { … }` in
    /// `View.conversationRowTrailingSwipeActions` fails this. Left outside, it would be the
    /// only button while the iPhone list selects, and a full swipe would report spam.
    func testSharedTrailingSwipe_disabled_offersNothing() throws {
        let source = try repositorySource(Self.sharedSwipePath)
        let swipe = try delimitedBody(
            after: "swipeActions(edge: .trailing, allowsFullSwipe: true)",
            open: "{",
            close: "}",
            in: source,
            path: Self.sharedSwipePath
        )
        let condition = try XCTUnwrap(
            swipe.range(of: "if isEnabled {"),
            "\(Self.sharedSwipePath): the trailing swipe no longer offers its buttons under `if isEnabled`"
        )
        let guarded = try delimitedRange(
            after: "if isEnabled",
            open: "{",
            close: "}",
            in: swipe,
            path: Self.sharedSwipePath
        )
        // `guarded.upperBound` is the condition's closing brace.
        let outside = swipe[..<condition.lowerBound] + swipe[swipe.index(after: guarded.upperBound)...]
        XCTAssertEqual(
            outside.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "Everything the trailing swipe offers must be inside `if isEnabled`:\n\(swipe)"
        )
        XCTAssertEqual(Self.buttonStarts(in: String(swipe[guarded])).count, 2, String(swipe[guarded]))
    }

    /// Revert-check: in `ConversationListView`, a `.swipeActions(edge: .trailing` of its own,
    /// an `onReportSpam` that reports at once, `isEnabled` no longer following Select mode, or
    /// the question's answer calling `reportSpamConversations(withIDs:)` (the Mac's batch entry
    /// point) in place of `reportSpamConversation(withID:)` fails this.
    func testIOSList_trailingSwipe_isTheSharedOneAndReportsSpamOnlyAfterTheQuestion() throws {
        try assertListUsesSharedSwipe(
            path: Self.iOSListPath,
            isEnabled: "isEnabled: !viewModel.isSelecting",
            onArchive: "onArchive: { viewModel.archiveConversation(withID: item.id) }",
            reportCall: "viewModel.reportSpamConversation(withID: conversationID)"
        )
    }

    /// Revert-check: in `MacConversationSidebar`, a `.swipeActions(edge: .trailing` of its own,
    /// an `onReportSpam` that reports at once, or a question whose answer no longer goes through
    /// `onReportSpam` (which moves the selection) fails this.
    func testMacSidebar_trailingSwipe_isTheSharedOneAndReportsSpamOnlyAfterTheQuestion() throws {
        try assertListUsesSharedSwipe(
            path: Self.macSidebarPath,
            isEnabled: "isEnabled: true",
            onArchive: "onArchive: { onArchive([item.id]) }",
            reportCall: "onReportSpam([conversationID])"
        )
    }

    // MARK: - Helpers

    /// The shared trailing swipe's buttons, in source order, each from its `Button` to the next.
    private func sharedSwipeButtons(file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let source = try repositorySource(Self.sharedSwipePath, file: file, line: line)
        let swipe = try delimitedBody(
            after: "swipeActions(edge: .trailing, allowsFullSwipe: true)",
            open: "{",
            close: "}",
            in: source,
            path: Self.sharedSwipePath,
            file: file,
            line: line
        )
        let starts = Self.buttonStarts(in: swipe)
        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : swipe.endIndex
            return String(swipe[starts[index]..<end])
        }
    }

    private func assertListUsesSharedSwipe(
        path: String,
        isEnabled: String,
        onArchive: String,
        reportCall: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try repositorySource(path, file: file, line: line)
        XCTAssertNil(
            source.range(of: ".swipeActions(edge: .trailing"),
            "\(path) has a trailing swipe of its own: it must use `conversationRowTrailingSwipeActions`",
            file: file,
            line: line
        )

        let swipeCall = try delimitedBody(
            after: ".conversationRowTrailingSwipeActions",
            open: "(",
            close: ")",
            in: source,
            path: path,
            file: file,
            line: line
        )
        XCTAssertTrue(swipeCall.contains(isEnabled), "\(path)\n\(swipeCall)", file: file, line: line)
        XCTAssertTrue(swipeCall.contains(onArchive), "\(path)\n\(swipeCall)", file: file, line: line)
        XCTAssertTrue(
            swipeCall.contains("onReportSpam: { conversationAwaitingSpamConfirmation = item.id }"),
            "\(path): the swipe's Report Spam must only ask\n\(swipeCall)",
            file: file,
            line: line
        )

        let answer = try delimitedBody(
            after: ".conversationSpamConfirmation(for: $conversationAwaitingSpamConfirmation)",
            open: "{",
            close: "}",
            in: source,
            path: path,
            file: file,
            line: line
        )
        XCTAssertTrue(answer.contains(reportCall), "\(path)\n\(answer)", file: file, line: line)
    }

    /// Where each button of `text` starts, in either spelling: `Button(` and `Button {`.
    private static func buttonStarts(in text: String) -> [String.Index] {
        let pattern = try! NSRegularExpression(pattern: #"\bButton\s*[({]"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text)?.lowerBound }
    }

    /// The text between the first `open` at or after `marker` in `text` and its matching
    /// `close`. See `delimitedRange`.
    private func delimitedBody(
        after marker: String,
        open: Character,
        close: Character,
        in text: String,
        path: String,
        openingIsInMarker: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let range = try delimitedRange(
            after: marker,
            open: open,
            close: close,
            in: text,
            path: path,
            openingIsInMarker: openingIsInMarker,
            file: file,
            line: line
        )
        return String(text[range])
    }

    /// Where the text between the first `open` at or after `marker` in `text` and its matching
    /// `close` is; its `upperBound` is that `close`. Counts nesting of that one pair only, which
    /// holds for the Swift these suites read: none of it has the pair inside a string literal.
    ///
    /// - Parameter openingIsInMarker: The marker itself ends with `open` (`"{ name in"`), so
    ///   the body starts right after the marker.
    private func delimitedRange(
        after marker: String,
        open: Character,
        close: Character,
        in text: String,
        path: String,
        openingIsInMarker: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Range<String.Index> {
        let markerRange = try XCTUnwrap(
            text.range(of: marker),
            "\(path) no longer has `\(marker)`",
            file: file,
            line: line
        )
        let bodyStart: String.Index
        if openingIsInMarker {
            bodyStart = markerRange.upperBound
        } else {
            let opening = try XCTUnwrap(
                text[markerRange.upperBound...].firstIndex(of: open),
                "\(path): nothing opens with `\(open)` after `\(marker)`",
                file: file,
                line: line
            )
            bodyStart = text.index(after: opening)
        }
        var depth = 1
        var index = bodyStart
        while index < text.endIndex {
            let character = text[index]
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return bodyStart..<index
                }
            }
            index = text.index(after: index)
        }
        XCTFail("\(path): `\(marker)` is never closed with `\(close)`", file: file, line: line)
        throw UnclosedDelimiter()
    }

    /// Ends a test whose source could not be read the way it expects; the failure itself is
    /// recorded where it was found, with the file's path.
    private struct UnclosedDelimiter: Error {}
}
