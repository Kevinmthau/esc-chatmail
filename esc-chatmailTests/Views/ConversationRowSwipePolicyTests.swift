import XCTest
import CoreData
@testable import esc_chatmail

/// The rules of a conversation row's trailing swipe and of its Report Spam question
/// (`ConversationRowSwipePolicy`). That the swipe draws exactly these actions is pinned from
/// source by `ConversationListSwipeActionsSourceTests`, and read back from a real list's table
/// on the Mac by `ConversationRowTrailingSwipeActionsMacTests`.
@MainActor
final class ConversationRowSwipePolicyTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    /// Revert-check: swapping the two actions in `ConversationRowSwipePolicy.trailingActions`
    /// makes this fail. SwiftUI performs a full swipe with the first, so the swap would make a
    /// full swipe report spam.
    func testTrailingActions_enabled_archiveFirstThenReportSpam() {
        XCTAssertEqual(ConversationRowSwipePolicy.trailingActions(isEnabled: true), [.archive, .reportSpam])
    }

    /// Revert-check: returning `[.reportSpam]` (or anything) from
    /// `ConversationRowSwipePolicy.trailingActions` when disabled makes this fail: alone, Report
    /// Spam would be the first button and a full swipe would perform it.
    func testTrailingActions_disabled_offersNothing() {
        XCTAssertEqual(ConversationRowSwipePolicy.trailingActions(isEnabled: false), [])
    }

    /// Revert-check: making `TrailingAction.isDestructive` true for `.reportSpam` makes this
    /// fail.
    func testTrailingAction_onlyArchiveIsDestructive() {
        XCTAssertTrue(ConversationRowSwipePolicy.TrailingAction.archive.isDestructive)
        XCTAssertFalse(ConversationRowSwipePolicy.TrailingAction.reportSpam.isDestructive)
    }

    func testTrailingAction_reportSpam_isNamedAsTheMenusNameIt() {
        XCTAssertEqual(ConversationRowSwipePolicy.TrailingAction.reportSpam.title, "Report Spam")
        XCTAssertEqual(ConversationRowSwipePolicy.TrailingAction.archive.title, "Archive")
    }

    /// Revert-check: dropping the name from `ConversationRowSwipePolicy.questionTitle` makes
    /// this fail.
    func testQuestionTitle_namesTheConversation() throws {
        let request = ConversationRowSwipePolicy.SpamReportRequest(
            conversationID: try makeConversationID(),
            storedName: "  Weekly Deals  "
        )

        XCTAssertEqual(
            ConversationRowSwipePolicy.questionTitle(for: request),
            "Report \u{201C}Weekly Deals\u{201D} as spam?"
        )
    }

    func testQuestionTitle_noStoredName_asksAboutThisConversation() throws {
        let conversationID = try makeConversationID()
        for storedName in [nil, "", "   "] {
            let request = ConversationRowSwipePolicy.SpamReportRequest(
                conversationID: conversationID,
                storedName: storedName
            )
            XCTAssertNil(request.conversationName)
            XCTAssertEqual(
                ConversationRowSwipePolicy.questionTitle(for: request),
                "Report this conversation as spam?"
            )
        }
        XCTAssertEqual(ConversationRowSwipePolicy.questionTitle(for: nil), "Report this conversation as spam?")
    }

    /// Revert-check: deleting the cut in `ConversationRowSwipePolicy.questionTitle` makes this
    /// fail.
    func testQuestionTitle_longName_isCutToTheLimit() throws {
        let name = String(repeating: "a", count: ConversationRowSwipePolicy.questionNameLimit + 40)
        let request = ConversationRowSwipePolicy.SpamReportRequest(
            conversationID: try makeConversationID(),
            storedName: name
        )

        let title = ConversationRowSwipePolicy.questionTitle(for: request)

        let shown = try XCTUnwrap(title.split(separator: "\u{201C}").last?.split(separator: "\u{201D}").first)
        XCTAssertEqual(shown.count, ConversationRowSwipePolicy.questionNameLimit)
        XCTAssertTrue(shown.hasSuffix("…"))
    }

    /// Revert-check: making `ConversationRowSwipePolicy.conversationToReport` ignore
    /// `isQuestionPresented` makes this fail: the answer would report while the question's
    /// sheet is still being taken down.
    func testConversationToReport_waitsForTheQuestionToGo() throws {
        let request = ConversationRowSwipePolicy.SpamReportRequest(
            conversationID: try makeConversationID(),
            storedName: "Alice"
        )

        XCTAssertNil(ConversationRowSwipePolicy.conversationToReport(answered: request, isQuestionPresented: true))
        XCTAssertEqual(
            ConversationRowSwipePolicy.conversationToReport(answered: request, isQuestionPresented: false),
            request.conversationID
        )
        XCTAssertNil(ConversationRowSwipePolicy.conversationToReport(answered: nil, isQuestionPresented: false))
    }

    /// Revert-check: making `ConversationRowSwipePolicy.withdrawsQuestion` always false makes
    /// this fail: a question whose row has left would stay up to be answered.
    func testWithdrawsQuestion_onlyAQuestionWhoseRowHasLeft() {
        XCTAssertTrue(ConversationRowSwipePolicy.withdrawsQuestion(isQuestionPresented: true, conversationIsListed: false))
        XCTAssertFalse(ConversationRowSwipePolicy.withdrawsQuestion(isQuestionPresented: true, conversationIsListed: true))
        XCTAssertFalse(ConversationRowSwipePolicy.withdrawsQuestion(isQuestionPresented: false, conversationIsListed: false))
    }

    // MARK: - Helpers

    /// A conversation's object ID; a temporary one does, since only its identity is compared.
    private func makeConversationID() throws -> NSManagedObjectID {
        ConversationBuilder().withDisplayName("Row").build(in: context).objectID
    }
}
