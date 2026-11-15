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
}
