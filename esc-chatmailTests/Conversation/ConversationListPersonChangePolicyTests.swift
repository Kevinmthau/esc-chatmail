import XCTest
@testable import esc_chatmail

/// `ConversationListPersonChangePolicy`: which merged Person changes reach the list's
/// window rows. The fan-out it gates is pinned on a store in
/// `ConversationListViewModelPersonChangeTests`.
final class ConversationListPersonChangePolicyTests: XCTestCase {
    private typealias Entry = ConversationSnapshot.ParticipantDisplayName

    // Revert-check: the `shownNames` guard in `mayChangeWindowRows` (answering true for an
    // address no row shows sends every recipient a send pinned through a fetch).
    func testMayChangeWindowRows_addressNoRowShows_isFalse() {
        let shown = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: [[Entry(email: "alice@example.com", displayName: "Alice")]],
            forEmails: ["bob@example.com"]
        )

        XCTAssertFalse(
            ConversationListPersonChangePolicy.mayChangeWindowRows(
                normalizedEmail: "bob@example.com",
                displayName: "Bob",
                shownDisplayNamesByEmail: shown
            )
        )
    }

    // Revert-check: the final comparison in `mayChangeWindowRows` (answering true whenever
    // a row shows the address refetches for every inverse-only change of a window person).
    func testMayChangeWindowRows_everyRowAlreadyShowsTheName_isFalse() {
        let shown = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: [
                [Entry(email: "alice@example.com", displayName: "Alice")],
                [Entry(email: "alice@example.com", displayName: "Alice"), Entry(email: "bob@example.com", displayName: "")]
            ],
            forEmails: ["alice@example.com"]
        )

        XCTAssertFalse(
            ConversationListPersonChangePolicy.mayChangeWindowRows(
                normalizedEmail: "alice@example.com",
                displayName: "Alice",
                shownDisplayNamesByEmail: shown
            )
        )
    }

    func testMayChangeWindowRows_aRowShowsAnotherName_isTrue() {
        let shown = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: [[Entry(email: "alice@example.com", displayName: "Alice")]],
            forEmails: ["alice@example.com"]
        )

        XCTAssertTrue(
            ConversationListPersonChangePolicy.mayChangeWindowRows(
                normalizedEmail: "alice@example.com",
                displayName: "Alice Smith",
                shownDisplayNamesByEmail: shown
            )
        )
    }

    /// A name taken away is a change: the snapshot records a Person with no name as `""`.
    func testMayChangeWindowRows_nameRemoved_isTrue() {
        let shown = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: [[Entry(email: "alice@example.com", displayName: "Alice")]],
            forEmails: ["alice@example.com"]
        )

        XCTAssertTrue(
            ConversationListPersonChangePolicy.mayChangeWindowRows(
                normalizedEmail: "alice@example.com",
                displayName: nil,
                shownDisplayNamesByEmail: shown
            )
        )
    }

    /// Duplicate Persons for one address exist by design, each in rows of its own. A row
    /// showing the duplicate's name for the address must not stand for the row this
    /// Person is in, which may still show its old name.
    // Revert-check: comparing with `shownNames.contains(displayName ?? "")` in place of
    // equality answers false here, and the row with the old name is never refreshed.
    func testMayChangeWindowRows_aDuplicatePersonsRowShowsTheNewName_isStillTrue() {
        let shown = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: [
                [Entry(email: "alice@example.com", displayName: "Alice Smith")],
                [Entry(email: "alice@example.com", displayName: "Alice")]
            ],
            forEmails: ["alice@example.com"]
        )

        XCTAssertTrue(
            ConversationListPersonChangePolicy.mayChangeWindowRows(
                normalizedEmail: "alice@example.com",
                displayName: "Alice Smith",
                shownDisplayNamesByEmail: shown
            )
        )
    }

    /// A participant with no address is left out of every snapshot, so no change to it can
    /// show.
    func testMayChangeWindowRows_emptyAddress_isFalse() {
        let shown = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: [[Entry(email: "alice@example.com", displayName: "Alice")]],
            forEmails: [""]
        )

        XCTAssertFalse(
            ConversationListPersonChangePolicy.mayChangeWindowRows(
                normalizedEmail: "",
                displayName: "Someone",
                shownDisplayNamesByEmail: shown
            )
        )
    }

    func testShownDisplayNamesByEmail_collectsOnlyTheAddressesAskedFor() {
        let shown = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: [
                [Entry(email: "alice@example.com", displayName: "Alice"), Entry(email: "bob@example.com", displayName: "Bob")],
                [Entry(email: "alice@example.com", displayName: "")]
            ],
            forEmails: ["alice@example.com", "carol@example.com"]
        )

        XCTAssertEqual(shown, ["alice@example.com": ["Alice", ""]])
    }
}
