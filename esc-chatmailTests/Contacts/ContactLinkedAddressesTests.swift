import XCTest
@testable import esc_chatmail

/// Pins which addresses a set of contact cards links, and that a link never
/// reaches further than one card states: a wrong link merges two people's
/// chats, which is worse than the missing link it stands beside.
final class ContactLinkedAddressesTests: XCTestCase {
    private static let work = "morgan@corp.example"
    private static let home = "m.vale@mail.example"
    private static let me: Set<String> = ["me@example.com"]

    private var oneCard: ContactLinkedAddresses {
        ContactLinkedAddresses(contactAddressLists: [[Self.work, Self.home], ["solo@example.com"]])
    }

    // MARK: - Which addresses are linked

    func testInit_cardWithTwoAddresses_linksThem() {
        let links = oneCard

        XCTAssertEqual(links.groups, [[Self.home, Self.work]])
        XCTAssertTrue(links.isLinked(Self.work))
        XCTAssertTrue(links.isLinked(Self.home))
        XCTAssertFalse(links.isLinked("solo@example.com"), "A card with one address links nothing")
        XCTAssertEqual(
            links.canonicalAddress(for: Self.work, excluding: []),
            links.canonicalAddress(for: Self.home, excluding: [])
        )
    }

    func testInit_addressesAsStored_areNormalizedBeforeLinking() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            ["  Morgan@Corp.Example ", "M.Vale@Mail.Example"]
        ])

        XCTAssertEqual(links, oneCard)
    }

    /// Gmail ignores dots and "+tag", so these are one mailbox and one
    /// normalized address: there is nothing to link.
    func testInit_spellingsOfOneGmailMailbox_linkNothing() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            ["a.b@gmail.com", "ab+lists@googlemail.com"]
        ])

        XCTAssertTrue(links.isEmpty)
    }

    // Revert-check: the `cardCountByAddress[$0] == 1` filter in
    // `ContactLinkedAddresses.init(contactAddressLists:)`. Without it the
    // family address is linked on both cards, and the two parents' chats
    // would hash as one person's.
    func testInit_addressOnTwoPeoplesCards_linksNothingThroughIt() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            ["mom@x.example", "mom.work@x.example", "family@x.example"],
            ["dad@x.example", "family@x.example"]
        ])

        XCTAssertEqual(
            links.groups, [["mom.work@x.example", "mom@x.example"]],
            "A card's own addresses are still linked among themselves"
        )
        XCTAssertFalse(links.isLinked("family@x.example"))
        XCTAssertFalse(links.isLinked("dad@x.example"))
        XCTAssertNotEqual(
            links.canonicalAddress(for: "mom@x.example", excluding: []),
            links.canonicalAddress(for: "dad@x.example", excluding: [])
        )
    }

    // Revert-check: `standsAlone` in `ContactLinkedAddresses.init`. Without
    // it, the same person kept in two accounts puts two of their addresses
    // on two cards, and the rule above then links none of the three.
    func testInit_cardContainedInAnother_addsNothingAndTakesNothingAway() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            [Self.work, Self.home, "third@x.example"],
            [Self.work, Self.home]
        ])

        XCTAssertEqual(links.groups, [[Self.home, Self.work, "third@x.example"]])
    }

    func testInit_sameCardTwice_isOneCard() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            [Self.work, Self.home],
            [Self.home, Self.work],
            [Self.work]
        ])

        XCTAssertEqual(links, oneCard)
    }

    /// A card holding only the shared addresses is contained in both people's
    /// cards. Dropping it must not make their cards look like one person's.
    func testInit_cardContainedInTwoPeoplesCards_doesNotJoinThem() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            ["family@x.example", "home@x.example"],
            ["mom@x.example", "family@x.example", "home@x.example"],
            ["dad@x.example", "family@x.example", "home@x.example"]
        ])

        XCTAssertTrue(links.isEmpty)
    }

    func testInit_twoCardsSharingOneAddress_areNotChained() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            ["a@x.example", "b@x.example"],
            ["b@x.example", "c@x.example"]
        ])

        XCTAssertTrue(links.isEmpty, "a and c are linked by no card")
    }

    // MARK: - The address that stands for a person

    func testCanonicalAddress_unlinkedAddress_isItself() {
        XCTAssertEqual(oneCard.canonicalAddress(for: "solo@example.com", excluding: []), "solo@example.com")
        XCTAssertEqual(
            ContactLinkedAddresses.none.canonicalAddress(for: Self.work, excluding: []),
            Self.work
        )
    }

    // Revert-check: both `myAliases` tests in
    // `ContactLinkedAddresses.canonicalAddress(for:excluding:)`. A card that
    // lists one of the user's addresses beside its owner's must not make the
    // user's address stand for that person, nor that person's for the user.
    func testCanonicalAddress_cardListsOneOfTheUsersAddresses_neverUsesItForThePerson() {
        let alias = "aaa-shared@x.example"
        let links = ContactLinkedAddresses(contactAddressLists: [
            [alias, "partner@x.example", "partner.work@x.example"]
        ])

        XCTAssertEqual(
            links.canonicalAddress(for: "partner@x.example", excluding: [alias]),
            "partner.work@x.example",
            "The first linked address that is not the user's"
        )
        XCTAssertEqual(links.canonicalAddress(for: alias, excluding: [alias]), alias)
    }

    func testUnifiedParticipants_twoAddressesOfOnePerson_areOneKeyAndOneAddress() {
        let unified = oneCard.unifiedParticipants(
            [Self.work, "carol@x.example", Self.home],
            excluding: Self.me
        )

        XCTAssertEqual(unified.hashKeys.count, 2)
        XCTAssertEqual(
            unified.addresses, ["carol@x.example", Self.home],
            "One address for each person: the first of theirs that is present"
        )
    }

    /// A row is made from the address the message carried. The card's other
    /// address is not a participant until a message uses it.
    func testUnifiedParticipants_oneAddressOfALinkedPerson_keepsThatAddress() {
        let unified = oneCard.unifiedParticipants([Self.work], excluding: Self.me)

        XCTAssertEqual(unified.addresses, [Self.work])
        XCTAssertEqual(unified.hashKeys, [Self.home])
    }

    func testUnifiedParticipants_nothingLinked_returnsTheSortedAddresses() {
        let unified = ContactLinkedAddresses.none.unifiedParticipants(
            ["b@x.example", "a@x.example"],
            excluding: Self.me
        )

        XCTAssertEqual(unified.addresses, ["a@x.example", "b@x.example"])
        XCTAssertEqual(unified.hashKeys, ["a@x.example", "b@x.example"])
    }

    // MARK: - What changed between two maps

    func testAddressesLinkedDifferently_newLink_namesBothAddresses() {
        XCTAssertEqual(oneCard.addressesLinkedDifferently(from: .none), [Self.work, Self.home])
        XCTAssertEqual(ContactLinkedAddresses.none.addressesLinkedDifferently(from: oneCard), [Self.work, Self.home])
        XCTAssertTrue(oneCard.addressesLinkedDifferently(from: oneCard).isEmpty)
    }

    /// The address that stands for the person can change when the card gains
    /// one, so every address of the group counts as changed, and another
    /// card's unchanged group does not.
    func testAddressesLinkedDifferently_cardGainsAnAddress_namesTheWholeGroupOnly() {
        let before = ContactLinkedAddresses(contactAddressLists: [
            [Self.work, Self.home],
            ["k@x.example", "k2@x.example"]
        ])
        let after = ContactLinkedAddresses(contactAddressLists: [
            [Self.work, Self.home, "a.first@x.example"],
            ["k@x.example", "k2@x.example"]
        ])

        XCTAssertEqual(
            after.addressesLinkedDifferently(from: before),
            [Self.work, Self.home, "a.first@x.example"]
        )
    }

    // MARK: - Stored form

    func testEncoded_roundTrip_givesTheSameMap() {
        let links = ContactLinkedAddresses(contactAddressLists: [
            [Self.work, Self.home],
            ["mom@x.example", "mom.work@x.example", "family@x.example"],
            ["dad@x.example", "family@x.example"]
        ])

        XCTAssertEqual(ContactLinkedAddresses(encoded: links.encoded), links)
    }

    func testEncoded_nothingLinked_isNoValue() {
        XCTAssertNil(ContactLinkedAddresses.none.encoded)
        XCTAssertEqual(ContactLinkedAddresses(encoded: nil), .none)
    }

    func testInitEncoded_unreadableValue_isNothingLinked() {
        XCTAssertEqual(ContactLinkedAddresses(encoded: "not json"), .none)
        XCTAssertEqual(ContactLinkedAddresses(encoded: #"{"a":1}"#), .none)
    }
}
