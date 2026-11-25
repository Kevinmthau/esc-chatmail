import XCTest
@testable import esc_chatmail

/// Pins which Contacts cards count as the user's own (architecture review
/// 2026-11, contacts-person#1). The self set decides `isFromMe`, is removed
/// before every participant hash and is filtered out of reply recipients, so
/// a card that lists the user's address beside someone else's must not make
/// that person the user: their mail was drawn as the user's own bubbles and
/// their one-to-one chat became note-to-self.
final class SelfContactCardsTests: XCTestCase {
    private static let account = "kevin@gmail.com"
    private static let sendAs = "kevin@company.example"

    // MARK: - Cards that count

    func testSelfAddresses_usersOwnCard_countsWithEveryAddress() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [
                [Self.account, "kevin@icloud.example"],
                ["someone@else.example", "someone.else@work.example"]
            ],
            knownAddresses: [Self.account]
        )

        XCTAssertEqual(addresses, [Self.account, "kevin@icloud.example"])
    }

    /// The same person kept in two accounts' contacts is two cards that each
    /// list the user's address: neither is someone else's card.
    func testSelfAddresses_usersOwnCardKeptTwice_counts() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [
                [Self.account, "kevin@icloud.example"],
                [Self.account, "kevin@icloud.example"]
            ],
            knownAddresses: [Self.account]
        )

        XCTAssertEqual(addresses, [Self.account, "kevin@icloud.example"])
    }

    /// Gmail ignores dots and "+tag": a card that spells the account address
    /// another way is still the user's card.
    func testSelfAddresses_gmailDotVariantOnOwnCard_counts() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [["K.E.V.I.N+mail@gmail.com", "kevin@icloud.example"]],
            knownAddresses: [Self.account]
        )

        XCTAssertEqual(addresses, [Self.account, "kevin@icloud.example"])
    }

    /// A household card beside the user's own card leaves the user's own card
    /// counted: its other address is on no card of someone else's.
    func testSelfAddresses_ownCardBesideHouseholdCard_ownCardStillCounts() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [
                [Self.account, "kevin@icloud.example"],
                [Self.account, "jane@gmail.com"],
                ["jane@gmail.com", "jane@work.example"]
            ],
            knownAddresses: [Self.account]
        )

        XCTAssertEqual(addresses, [Self.account, "kevin@icloud.example"])
    }

    // MARK: - Cards that do not count

    // Revert-check: the `claimedByOthers` test in
    // `SelfContactCards.selfAddresses`. Without it the household card counts
    // and Jane's mail is the user's own.
    func testSelfAddresses_householdCard_partnerHasOwnCard_doesNotCount() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [
                [Self.account, "jane@gmail.com"],
                ["jane@gmail.com", "jane@work.example"]
            ],
            knownAddresses: [Self.account]
        )

        XCTAssertFalse(addresses.contains("jane@gmail.com"))
        XCTAssertEqual(addresses, [])
    }

    /// One foreign address on a card makes the whole card suspect: a company
    /// card names colleagues, and only some of them may have a card.
    func testSelfAddresses_companyCardListingColleagues_doesNotCountAnyColleague() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [
                [Self.sendAs, "alice@company.example", "bob@company.example"],
                ["alice@company.example"]
            ],
            knownAddresses: [Self.account, Self.sendAs]
        )

        XCTAssertFalse(addresses.contains("alice@company.example"))
        XCTAssertFalse(addresses.contains("bob@company.example"), "Bob has no card, but he is on a card that is not the user's")
    }

    /// The other card spells the partner's Gmail address another way: it is
    /// still the partner's mailbox.
    func testSelfAddresses_partnerCardSpellsGmailDifferently_stillDisqualifies() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [
                [Self.account, "jane.doe@gmail.com"],
                ["JaneDoe+news@googlemail.com"]
            ],
            knownAddresses: [Self.account]
        )

        XCTAssertEqual(addresses, [])
    }

    // MARK: - Limits

    /// HONEST SCOPE: a card that lists the user beside someone who has no card
    /// of their own still counts, as every card did before this rule. Nothing
    /// in Contacts tells that person apart from a second address of the user.
    func testSelfAddresses_householdCard_partnerHasNoCard_stillCounts() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [[Self.account, "jane@gmail.com"]],
            knownAddresses: [Self.account]
        )

        XCTAssertEqual(addresses, [Self.account, "jane@gmail.com"])
    }

    func testSelfAddresses_noKnownAddresses_countsNothing() {
        let addresses = SelfContactCards.selfAddresses(
            contactAddressLists: [[Self.account, "kevin@icloud.example"]],
            knownAddresses: [String]()
        )

        XCTAssertEqual(addresses, [])
    }
}
