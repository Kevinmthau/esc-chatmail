import XCTest
@testable import esc_chatmail

/// Pins which of a person's addresses a reply goes to once a contact card
/// links them and their chat counts them as one participant. The rule may
/// exchange a participant's address only for one the message being replied to
/// carried: a reply must never reach an address the card merely lists.
final class ReplyLinkedAddressPolicyTests: XCTestCase {
    private static let work = "morgan@corp.example"
    private static let home = "m.vale@mail.example"
    private static let carol = "carol@example.com"
    private static let me: Set<String> = ["me@example.com"]
    private static let oneCard = ContactLinkedAddresses(contactAddressLists: [[work, home]])

    private func recipients(
        rows: [String],
        target: [String],
        links: ContactLinkedAddresses = ReplyLinkedAddressPolicyTests.oneCard
    ) -> [String] {
        ReplyLinkedAddressPolicy.recipients(
            conversationRecipients: rows,
            targetRecipients: target,
            contactLinks: links,
            userAddresses: Self.me
        )
    }

    // Revert-check: the `addressesInUse` exchange in
    // `ReplyLinkedAddressPolicy.recipients`. Returning the rows, a reply to
    // mail from the person's second address goes to the first.
    func testRecipients_personWroteFromTheirOtherAddress_repliesToThatAddress() {
        XCTAssertEqual(recipients(rows: [Self.work], target: [Self.home]), [Self.home])
    }

    func testRecipients_personWroteFromTheRowsAddress_keepsIt() {
        XCTAssertEqual(recipients(rows: [Self.work], target: [Self.work]), [Self.work])
    }

    /// The person copied their other address, so both are in use and a reply
    /// keeps both, in the target's order.
    func testRecipients_targetCarriesBothAddresses_repliesToBoth() {
        XCTAssertEqual(
            recipients(rows: [Self.work], target: [Self.home, Self.work]),
            [Self.home, Self.work]
        )
    }

    func testRecipients_groupReply_exchangesOnlyTheLinkedParticipantAndAddsNobody() {
        XCTAssertEqual(
            recipients(
                rows: [Self.work, Self.carol],
                target: [Self.home, Self.carol, "stranger@example.com"]
            ),
            [Self.home, Self.carol],
            "An address of the target that is no participant's is not a recipient"
        )
    }

    /// With no message to go by, or one that does not name the person, the
    /// row's address is the only one known to be theirs here.
    func testRecipients_targetDoesNotNameThePerson_keepsTheRowsAddress() {
        XCTAssertEqual(recipients(rows: [Self.work], target: []), [Self.work])
        XCTAssertEqual(recipients(rows: [Self.work], target: [Self.carol]), [Self.work])
    }

    func testRecipients_twoRowsForOnePerson_addressTheTargetsAddressOnce() {
        XCTAssertEqual(recipients(rows: [Self.work, Self.home], target: [Self.home]), [Self.home])
    }

    /// A conversation with no linked participant gets its rows back exactly,
    /// repeats included: nothing about replies changes for it.
    func testRecipients_noLinkedParticipant_returnsTheRowsUntouched() {
        let rows = [Self.carol, "Carol@Example.com", "dave@example.com"]

        XCTAssertEqual(recipients(rows: rows, target: [Self.home, "dave@example.com"]), rows)
        XCTAssertEqual(recipients(rows: [Self.work], target: [Self.home], links: .none), [Self.work])
    }

    /// A card that lists one of the user's own addresses beside its owner's
    /// does not make the user a recipient of their own reply.
    func testRecipients_cardListsOneOfTheUsersAddresses_neverAddressesTheUser() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            ["me@example.com", "partner@x.example", "partner.work@x.example"]
        ])

        XCTAssertEqual(
            recipients(rows: ["partner@x.example"], target: ["partner.work@x.example"], links: links),
            ["partner.work@x.example"]
        )
    }

    // MARK: - Whether the rows can answer for a message

    private static let alex = "alex@example.com"
    private static let sam = "sam@example.com"

    private func rowsCanAnswer(
        rows: [String],
        message: [String],
        author: String?,
        links: ContactLinkedAddresses = .none
    ) -> Bool {
        ReplyLinkedAddressPolicy.rowsCanAnswer(
            conversationRecipients: rows,
            messageParticipants: message,
            messageAuthor: author,
            contactLinks: links,
            userAddresses: Self.me
        )
    }

    func testRowsCanAnswer_messageOfTheRowsPeople_isAnswered() {
        XCTAssertTrue(rowsCanAnswer(rows: [Self.alex], message: [Self.alex], author: Self.alex))
        XCTAssertTrue(
            rowsCanAnswer(rows: [Self.carol, Self.alex], message: ["Alex@Example.com", Self.carol], author: Self.carol)
        )
        XCTAssertTrue(rowsCanAnswer(rows: [Self.alex], message: [Self.alex], author: "me@example.com"))
    }

    // Revert-check: the `rows.isSubset(of:)` guard in
    // `ReplyLinkedAddressPolicy.rowsCanAnswer`. The author is one of the rows
    // here, or the user, so only that guard sees that a row's person was
    // never on the message.
    func testRowsCanAnswer_rowNamesSomeoneWhoIsNotOnTheMessage_isNotAnswered() {
        XCTAssertFalse(
            rowsCanAnswer(rows: [Self.alex, Self.carol], message: [Self.sam, Self.carol], author: Self.carol)
        )
        XCTAssertFalse(rowsCanAnswer(rows: [Self.alex], message: [Self.sam], author: "me@example.com"))
        XCTAssertFalse(rowsCanAnswer(rows: [Self.alex], message: [Self.sam], author: nil))
    }

    // Revert-check: the author test that ends
    // `ReplyLinkedAddressPolicy.rowsCanAnswer`. Every row is on the message
    // here, so only that test sees that the person being answered has no row.
    func testRowsCanAnswer_authorIsNobodysRow_isNotAnswered() {
        XCTAssertFalse(rowsCanAnswer(rows: [Self.alex], message: [Self.alex, Self.sam], author: Self.sam))
    }

    /// Rows that leave out someone who did not write the message keep both
    /// promises: the reply goes to the rows and adds nobody.
    func testRowsCanAnswer_rowsLeaveOutSomeoneWhoDidNotWriteIt_isAnswered() {
        let message = [Self.alex, Self.sam]

        XCTAssertTrue(rowsCanAnswer(rows: [Self.alex], message: message, author: Self.alex))
        XCTAssertTrue(rowsCanAnswer(rows: [Self.alex], message: message, author: "me@example.com"))
        XCTAssertTrue(rowsCanAnswer(rows: [Self.alex], message: message, author: nil))
        XCTAssertTrue(rowsCanAnswer(rows: [Self.alex], message: message, author: "  "))
    }

    /// Two addresses are one person only while a card links them. That is
    /// the whole case: the same rows and message, before and after the card
    /// stops listing both.
    func testRowsCanAnswer_twoAddressesOfOneCard_areOnePersonOnlyWhileLinked() {
        XCTAssertTrue(rowsCanAnswer(rows: [Self.work], message: [Self.home], author: Self.home, links: Self.oneCard))
        XCTAssertFalse(rowsCanAnswer(rows: [Self.work], message: [Self.home], author: Self.home, links: .none))
    }

    // MARK: - Recipients outside the conversation

    private func outside(
        recipients: [String],
        rows: [String],
        links: ContactLinkedAddresses = .none
    ) -> [String] {
        ReplyLinkedAddressPolicy.recipientsOutsideConversation(
            recipients: recipients,
            conversationRecipients: rows,
            contactLinks: links,
            userAddresses: Self.me
        )
    }

    // Revert-check: the filter of
    // `ReplyLinkedAddressPolicy.recipientsOutsideConversation` (return
    // `recipients`, or `[]`). The composer names these ahead of the chat's
    // own people, so with all of them, or none, the order it names a reply's
    // recipients in is the sender's again.
    /// The recipients the rows do not name, in the reply's order, whatever
    /// case an address was written in.
    func testRecipientsOutsideConversation_areThoseTheRowsDoNotName_inTheRepliesOrder() {
        XCTAssertEqual(
            outside(
                recipients: [Self.carol, "x@elsewhere.example", "Morgan@Corp.Example", "y@elsewhere.example"],
                rows: [Self.work, Self.carol]
            ),
            ["x@elsewhere.example", "y@elsewhere.example"]
        )
        XCTAssertEqual(outside(recipients: [Self.carol], rows: [Self.work, Self.carol]), [])
    }

    // Revert-check: the `person` mapping in
    // `ReplyLinkedAddressPolicy.recipientsOutsideConversation` (compare the
    // normalized addresses themselves). A linked participant answered at
    // their other address is then called an outsider and named ahead of
    // someone the chat's title really does not name.
    /// People, not addresses: a participant answered at another address of
    /// their card is the chat's own, for as long as the card links the two.
    func testRecipientsOutsideConversation_linkedParticipantAtAnotherAddress_isNotOutside() {
        let recipients = [Self.home, "x@elsewhere.example"]

        XCTAssertEqual(
            outside(recipients: recipients, rows: [Self.work], links: Self.oneCard),
            ["x@elsewhere.example"]
        )
        XCTAssertEqual(outside(recipients: recipients, rows: [Self.work], links: .none), recipients)
    }
}
