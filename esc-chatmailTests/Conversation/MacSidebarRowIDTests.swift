import CoreData
import XCTest
@testable import esc_chatmail

/// The identity of a row in the Mac sidebar's list. The type is pure and compiles on both
/// platforms, so these run in the iOS suite and in `Mac.xctestplan`.
///
/// HONEST SCOPE: this pins the type and its two conversions. That the sidebar gives the list
/// these ids is pinned from its source (`MacConversationSidebarSourceTests`), and that a Mac
/// list then draws moved rows where they belong is pinned in the Mac plan
/// (`MacConversationSidebarRowIdentityTests`).
@MainActor
final class MacSidebarRowIDTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.makeMainQueueViewContext()
    }

    override func tearDown() async throws {
        viewContext = nil
        stack = nil
        try await super.tearDown()
    }

    /// The whole reason for the type: a Mac list goes wrong with a row id that is an object.
    ///
    /// Revert-check: declaring `MacSidebarRowID` as a `final class` makes this fail.
    func testRowID_isAValue_notAnObject() {
        let rowID = MacSidebarRowID(conversationID: makeConversation().objectID)

        XCTAssertEqual(Mirror(reflecting: rowID).displayStyle, .struct)
        XCTAssertFalse(type(of: rowID as Any) is AnyClass)
    }

    /// A row keeps its identity from one publish of the list to the next: two ids made from
    /// one conversation are one id, and ids of two conversations are not.
    ///
    /// Revert-check: writing `==` on `MacSidebarRowID` to return false (or true) for every pair
    /// makes this fail.
    func testRowID_isTheSame_exactlyWhenItsConversationIs() {
        let first = makeConversation().objectID
        let second = makeConversation().objectID

        XCTAssertEqual(MacSidebarRowID(conversationID: first), MacSidebarRowID(conversationID: first))
        XCTAssertEqual(
            MacSidebarRowID(conversationID: first).hashValue,
            MacSidebarRowID(conversationID: first).hashValue
        )
        XCTAssertNotEqual(MacSidebarRowID(conversationID: first), MacSidebarRowID(conversationID: second))
    }

    /// Revert-check: returning `[]` from `MacSidebarRowID.rowIDs(for:)` makes this fail: the
    /// list would be told nothing is selected, whatever the mailbox has selected.
    func testRowIDs_forTheMailboxsSelection_areOneForEachConversation() {
        let first = makeConversation().objectID
        let second = makeConversation().objectID

        XCTAssertEqual(
            MacSidebarRowID.rowIDs(for: [first, second]),
            [MacSidebarRowID(conversationID: first), MacSidebarRowID(conversationID: second)]
        )
        XCTAssertEqual(MacSidebarRowID.rowIDs(for: []), [])
    }

    /// Revert-check: returning `[]` from `MacSidebarRowID.conversationIDs(for:)` makes this
    /// fail: a click on a row would open no chat.
    func testConversationIDs_forTheListsSelection_areTheRowsConversations() {
        let first = makeConversation().objectID
        let second = makeConversation().objectID
        let rowIDs: Set<MacSidebarRowID> = [
            MacSidebarRowID(conversationID: first),
            MacSidebarRowID(conversationID: second)
        ]

        XCTAssertEqual(MacSidebarRowID.conversationIDs(for: rowIDs), [first, second])
        XCTAssertEqual(MacSidebarRowID.conversationIDs(for: []), [])
    }

    /// HONEST SCOPE: `sidebarRowID` is one line, and no change to it that still compiles was
    /// found that this could catch and the sidebar's own tests could not. It is here so the
    /// property has a test beside its type; a sidebar whose rows carried another conversation's
    /// id fails `MacConversationSidebarRowIdentityTests`' two selection tests.
    func testListItem_sidebarRowID_holdsTheItemsOwnConversation() {
        let conversation = makeConversation()
        let item = ConversationListItem(conversation: conversation)

        XCTAssertEqual(item.sidebarRowID.conversationID, conversation.objectID)
        XCTAssertEqual(item.sidebarRowID, MacSidebarRowID(conversationID: item.id))
    }

    private func makeConversation() -> Conversation {
        ConversationBuilder()
            .asList()
            .withListId("\(UUID().uuidString).example.com")
            .build(in: viewContext)
    }
}
