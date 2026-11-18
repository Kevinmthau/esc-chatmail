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
    /// requestIsListed)` that withdraws the question, or the withdrawal when a question comes
    /// up (`.onChange(of: request)`), fails this; so does calling `onConfirm` in place of the
    /// deferred `Task`, or a title read from the live request alone.
    func testSpamConfirmation_appliesThePolicysRules() throws {
        let source = try repositorySource(Self.confirmationPath)
        let body = try sourceBlock(
            after: "func body(content: Content) -> some View",
            open: "{",
            close: "}",
            in: source,
            path: Self.confirmationPath
        )
        XCTAssertTrue(body.contains("ConversationRowSwipePolicy.questionTitle(for: request ?? shownRequest)"), body)
        let raised = try sourceBlock(
            after: ".onChange(of: request) { _, newRequest in",
            open: "{",
            close: "}",
            in: body,
            path: Self.confirmationPath,
            openingIsInMarker: true
        )
        XCTAssertTrue(raised.contains("shownRequest = newRequest"), raised)
        XCTAssertTrue(raised.contains("conversationIsListed: isListed(newRequest.conversationID)"), raised)
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

    /// Revert-check: in `ConversationListView`, an `onReportSpam` that reports at once or names
    /// the stored title, a row whose leaving state no longer comes from
    /// `conversationIDsLeavingList` (`let isLeavingList = false`), a dim or a leading swipe that
    /// no longer follows it, an answer calling `reportSpamConversations(withIDs:)` (the batch
    /// entry point), or the question moved inside the `List`, onto the rows, fails this.
    func testIOSList_trailingSwipeIsTheSharedOneAndItsQuestionIsOnTheList() throws {
        try assertListUsesSharedSwipe(
            path: Self.iOSListPath,
            listHead: "\n        List {",
            isSelecting: "viewModel.isSelecting",
            onArchive: "onArchive: { viewModel.archiveConversation(withID: item.id) }",
            currentUserEmail: "authSession.userEmail ?? \"\"",
            participantLoader: "deps.participantLoader",
            onConfirm: "onConfirm: { viewModel.reportSpamConversation(withID: $0) }"
        )
    }

    /// Revert-check: in `MacConversationSidebar`, an `onReportSpam` that reports at once or
    /// names the stored title, a row whose leaving state no longer comes from
    /// `conversationIDsLeavingList`, a dim or a leading swipe that no longer follows it, a swipe
    /// whose Archive or answer no longer goes through `onSwipeAction` (which moves the
    /// selection and runs the row's single-conversation action), or the question moved inside
    /// the `List`, onto the rows, fails this.
    func testMacSidebar_trailingSwipeIsTheSharedOneAndItsQuestionIsOnTheList() throws {
        try assertListUsesSharedSwipe(
            path: Self.macSidebarPath,
            listHead: "\n        List(selection: rowSelection) {",
            isSelecting: "false",
            onArchive: "onArchive: { onSwipeAction(.archive, item.id) }",
            currentUserEmail: "currentUserEmail",
            participantLoader: "participantLoader",
            onConfirm: "onConfirm: { onSwipeAction(.reportSpam, $0) }"
        )
    }

    /// The Mac's swipe runs the same single-conversation actions as the iPhone's, after the
    /// selection moves, so the shared swipe follows one set of rules on both.
    ///
    /// Revert-check: in `MacMailboxView.swipeAction(_:on:)`, calling the batch
    /// `reportSpamConversations(withIDs:)` or `archiveConversations(withIDs:)`, or acting
    /// without `performListAction`, fails this.
    func testMacMailbox_swipeRunsTheRowsSingleConversationActionsAfterMovingTheSelection() throws {
        let path = "esc-chatmail/Platform/MacMailboxView.swift"
        let source = try repositorySource(path)
        XCTAssertTrue(source.contains("onSwipeAction: { swipeAction($0, on: $1) }"), path)
        let body = try sourceBlock(
            after: "private func swipeAction(_ action: ConversationRowSwipePolicy.TrailingAction, on conversationID: NSManagedObjectID)",
            open: "{",
            close: "}",
            in: source,
            path: path
        )
        XCTAssertTrue(body.contains("performListAction(on: [conversationID]) { targets in"), body)
        XCTAssertTrue(body.contains("case .archive: viewModel.archiveConversation(withID: target)"), body)
        XCTAssertTrue(body.contains("case .reportSpam: viewModel.reportSpamConversation(withID: target)"), body)
        XCTAssertFalse(body.contains("withIDs:"), body)
    }

    // MARK: - Helpers

    private func assertListUsesSharedSwipe(
        path: String,
        listHead: String,
        isSelecting: String,
        onArchive: String,
        currentUserEmail: String,
        participantLoader: String,
        onConfirm: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try repositorySource(path, file: file, line: line)
        let collapsedSource = Self.collapsingWhitespace(source)

        // The row's leaving state, from the view model, decides its dim and both swipes.
        for expected in [
            "let isLeavingList = viewModel.conversationIDsLeavingList.contains(item.id)",
            "let offersSwipes = ConversationRowSwipePolicy.offersSwipes( isSelecting: \(isSelecting), isLeavingList: isLeavingList )",
            ".opacity(ConversationRowSwipePolicy.rowOpacity(isLeavingList: isLeavingList))",
        ] {
            XCTAssertTrue(collapsedSource.contains(expected), "\(path) no longer has `\(expected)`", file: file, line: line)
        }
        let leadingSwipe = try sourceBlock(
            after: ".swipeActions(edge: .leading, allowsFullSwipe: true)",
            open: "{",
            close: "}",
            in: source,
            path: path,
            file: file,
            line: line
        )
        let trimmedLeading = leadingSwipe.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            trimmedLeading.hasPrefix("if offersSwipes {"),
            "\(path): the leading swipe must offer its button only `if offersSwipes`:\n\(leadingSwipe)",
            file: file,
            line: line
        )
        let guarded = try sourceBlockRange(
            after: "if offersSwipes {",
            open: "{",
            close: "}",
            in: trimmedLeading,
            path: path,
            file: file,
            line: line
        )
        XCTAssertEqual(
            trimmedLeading[trimmedLeading.index(after: guarded.upperBound)...]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "\(path): nothing may follow `if offersSwipes { … }` in the leading swipe:\n\(leadingSwipe)",
            file: file,
            line: line
        )

        let swipeCall = try sourceBlock(
            after: ".conversationRowTrailingSwipeActions",
            open: "(",
            close: ")",
            in: source,
            path: path,
            file: file,
            line: line
        )
        XCTAssertTrue(swipeCall.contains("isEnabled: offersSwipes,"), "\(path)\n\(swipeCall)", file: file, line: line)
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
            "spamReportAwaitingAnswer = .init( conversationID: item.id, shownName: ConversationRowView.displayedName( "
                + "snapshot: item.snapshot, conversationObjectID: item.id, currentUserEmail: \(currentUserEmail), "
                + "participantLoader: \(participantLoader) ) )",
            "\(path): the swipe's Report Spam must only ask, naming the row as it shows",
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
