import XCTest

/// Pins, from source, that the conversation rows' trailing swipe is one definition shared by
/// the iPhone's list and the Mac's sidebar, that it draws `ConversationRowSwipePolicy`'s actions
/// and nothing else, and that its Report Spam only asks, with the question attached to each list.
///
/// What the swipe offers and in which order is the policy's, unit-tested by
/// `ConversationRowSwipePolicyTests`; `ConversationRowTrailingSwipeActionsMacTests` reads the
/// order back from a real list's table on the Mac. No test can perform a swipe on the iPhone, so
/// there these source pins are all there is.
///
/// HONEST SCOPE: nothing here swipes a row or presents the question. Neither has been seen in
/// the app, on the iPhone or the Mac.
final class ConversationListSwipeActionsSourceTests: XCTestCase {
    private static let sharedSwipePath = "esc-chatmail/Views/Main/View+ConversationRowSwipeActions.swift"
    private static let confirmationPath = "esc-chatmail/Views/Main/ConversationSpamConfirmation.swift"
    private static let iOSListPath = "esc-chatmail/Views/Main/ConversationListView.swift"
    private static let macSidebarPath = "esc-chatmail/Platform/MacConversationSidebar.swift"

    /// Revert-check: in `View.conversationRowTrailingSwipeActions`, a button added before or
    /// after the `ForEach` fails this; so does swapping the `switch`'s calls, or a fixed
    /// `role: .destructive` in place of the action's own.
    func testSharedTrailingSwipe_drawsThePolicysActionsAndNothingElse() throws {
        let source = try repositorySource(Self.sharedSwipePath)
        let swipe = try sourceBlock(
            after: "swipeActions(edge: .trailing, allowsFullSwipe: true)",
            open: "{",
            close: "}",
            in: source,
            path: Self.sharedSwipePath
        )
        let forEachHead = "ForEach(ConversationRowSwipePolicy.trailingActions(isEnabled: isEnabled), id: \\.self) { action in"
        let trimmed = swipe.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix(forEachHead), "The swipe must open with the policy's actions:\n\(swipe)")
        let eachAction = try sourceBlock(
            after: forEachHead,
            open: "{",
            close: "}",
            in: trimmed,
            path: Self.sharedSwipePath,
            openingIsInMarker: true
        )
        XCTAssertTrue(
            trimmed.hasSuffix(eachAction + "}"),
            "Nothing may follow the policy's actions in the swipe:\n\(swipe)"
        )
        XCTAssertEqual(Self.buttonCount(in: eachAction), 1, eachAction)
        XCTAssertTrue(eachAction.contains("Button(role: action.isDestructive ? .destructive : nil)"), eachAction)
        XCTAssertTrue(eachAction.contains("case .archive: onArchive()"), eachAction)
        XCTAssertTrue(eachAction.contains("case .reportSpam: onReportSpam()"), eachAction)
        XCTAssertTrue(eachAction.contains("SwiftUI.Label(action.title, systemImage: action.systemImage)"), eachAction)
    }

    /// Revert-check: in `ConversationSpamConfirmation`, deleting the `.onChange(of:
    /// requestIsListed)` that withdraws the question fails this; so does calling `onConfirm`
    /// in place of the deferred `Task`, or a title that no longer comes from the policy.
    func testSpamConfirmation_appliesThePolicysRules() throws {
        let source = try repositorySource(Self.confirmationPath)
        let body = try sourceBlock(
            after: "func body(content: Content) -> some View",
            open: "{",
            close: "}",
            in: source,
            path: Self.confirmationPath
        )
        XCTAssertTrue(body.contains("ConversationRowSwipePolicy.questionTitle(for: request)"), body)
        XCTAssertTrue(body.contains("Text(ConversationRowSwipePolicy.questionMessage)"), body)
        XCTAssertTrue(body.contains(#"Button("Report Spam", role: .destructive)"#), body)
        let withdrawal = try sourceBlock(
            after: ".onChange(of: requestIsListed)",
            open: "{",
            close: "}",
            in: body,
            path: Self.confirmationPath
        )
        XCTAssertTrue(withdrawal.contains("ConversationRowSwipePolicy.withdrawsQuestion("), withdrawal)
        XCTAssertTrue(withdrawal.contains("request = nil"), withdrawal)

        let report = try sourceBlock(
            after: "private func reportIfQuestionIsGone()",
            open: "{",
            close: "}",
            in: source,
            path: Self.confirmationPath
        )
        XCTAssertTrue(report.contains("ConversationRowSwipePolicy.conversationToReport("), report)
        let deferred = try sourceBlock(
            after: "Task { @MainActor in",
            open: "{",
            close: "}",
            in: report,
            path: Self.confirmationPath,
            openingIsInMarker: true
        )
        XCTAssertTrue(deferred.contains("guard isListed(conversationID) else { return }"), deferred)
        XCTAssertTrue(deferred.contains("onConfirm(conversationID)"), deferred)
        XCTAssertEqual(
            report.components(separatedBy: "onConfirm(").count - 1,
            1,
            "The answer may report only from the deferred task:\n\(report)"
        )
    }

    /// `swipeActions` with no edge is a trailing swipe too. A list's own trailing swipe would
    /// bypass the shared one, and could make a full swipe report spam with no question.
    ///
    /// Revert-check: adding `.swipeActions { … }` or `.swipeActions(allowsFullSwipe: true) { … }`
    /// to a row in either file fails this, as does `.swipeActions(edge: .trailing`.
    func testLists_haveNoTrailingSwipeOfTheirOwn() throws {
        for path in [Self.iOSListPath, Self.macSidebarPath] {
            let source = try repositorySource(path)
            let calls = source.components(separatedBy: ".swipeActions").dropFirst()
            XCTAssertFalse(calls.isEmpty, "\(path) has no leading swipe any more")
            for call in calls {
                XCTAssertTrue(
                    call.hasPrefix("(edge: .leading"),
                    "\(path): every `.swipeActions` there must be the leading one; the trailing one is `conversationRowTrailingSwipeActions`:\n.swipeActions\(call.prefix(80))"
                )
            }
        }
    }

    /// Revert-check: in `ConversationListView`, an `onReportSpam` that reports at once, an
    /// `isEnabled` that no longer follows Select mode or the row's running report, an answer
    /// calling `reportSpamConversations(withIDs:)` (the Mac's batch entry point), or the
    /// question moved inside the `List`, onto the rows, fails this.
    func testIOSList_trailingSwipeIsTheSharedOneAndItsQuestionIsOnTheList() throws {
        try assertListUsesSharedSwipe(
            path: Self.iOSListPath,
            listHead: "\n        List {",
            isEnabled: "isEnabled: !viewModel.isSelecting && !isBeingReportedAsSpam",
            onArchive: "onArchive: { viewModel.archiveConversation(withID: item.id) }",
            onConfirm: "onConfirm: { viewModel.reportSpamConversation(withID: $0) }"
        )
    }

    /// Revert-check: in `MacConversationSidebar`, an `onReportSpam` that reports at once, an
    /// answer that no longer goes through `onReportSpam` (which moves the selection), or the
    /// question moved inside the `List`, onto the rows, fails this.
    func testMacSidebar_trailingSwipeIsTheSharedOneAndItsQuestionIsOnTheList() throws {
        try assertListUsesSharedSwipe(
            path: Self.macSidebarPath,
            listHead: "\n        List(selection: rowSelection) {",
            isEnabled: "isEnabled: true",
            onArchive: "onArchive: { onArchive([item.id]) }",
            onConfirm: "onConfirm: { onReportSpam([$0]) }"
        )
    }

    // MARK: - Helpers

    private func assertListUsesSharedSwipe(
        path: String,
        listHead: String,
        isEnabled: String,
        onArchive: String,
        onConfirm: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try repositorySource(path, file: file, line: line)

        let swipeCall = try sourceBlock(
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
        let onReportSpam = try sourceBlock(
            after: "onReportSpam: {",
            open: "{",
            close: "}",
            in: swipeCall,
            path: path,
            openingIsInMarker: true,
            file: file,
            line: line
        )
        XCTAssertEqual(
            Self.collapsingWhitespace(onReportSpam),
            "spamReportAwaitingAnswer = .init( conversationID: item.id, storedName: item.snapshot.displayNameHint )",
            "\(path): the swipe's Report Spam must only ask, naming the row",
            file: file,
            line: line
        )

        let confirmationMarker = ".conversationSpamConfirmation("
        XCTAssertEqual(
            source.components(separatedBy: confirmationMarker).count - 1,
            1,
            "\(path) should ask in one place",
            file: file,
            line: line
        )
        let list = try sourceBlockRange(
            after: listHead,
            open: "{",
            close: "}",
            in: source,
            path: path,
            file: file,
            line: line
        )
        let confirmation = try XCTUnwrap(source.range(of: confirmationMarker), file: file, line: line)
        XCTAssertGreaterThan(
            confirmation.lowerBound,
            list.upperBound,
            "\(path): the question must be on the list, after its content, not on a row",
            file: file,
            line: line
        )
        let confirmationCall = try sourceBlock(
            after: confirmationMarker,
            open: "(",
            close: ")",
            in: source,
            path: path,
            openingIsInMarker: true,
            file: file,
            line: line
        )
        XCTAssertTrue(
            confirmationCall.contains("for: $spamReportAwaitingAnswer"),
            "\(path)\n\(confirmationCall)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            confirmationCall.contains("isListed: { viewModel.listsConversation(withID: $0) }"),
            "\(path)\n\(confirmationCall)",
            file: file,
            line: line
        )
        XCTAssertTrue(confirmationCall.contains(onConfirm), "\(path)\n\(confirmationCall)", file: file, line: line)
    }

    /// `text` with every run of whitespace made one space, so a pin does not depend on layout.
    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// How many buttons `text` makes, in either spelling: `Button(` and `Button {`.
    private static func buttonCount(in text: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: #"\bButton\s*[({]"#)
        return pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
