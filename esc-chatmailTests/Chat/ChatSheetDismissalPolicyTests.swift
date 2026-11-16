import Contacts
import XCTest
@testable import esc_chatmail

/// `ChatSheetDismissalPolicy` decides whether a dismissal of the chat's sheet clears the chat's
/// destination state or belongs to a sheet that another destination is replacing. It decides
/// from the destination the chat recorded as on screen, and a record that was behind is how
/// the Mac's New Contact sheet came to have no button that closed it (build 562, 2026-11-15).
///
/// HONEST SCOPE: these run the rule on the ids of real destinations. They cannot tell that
/// `ChatView` keeps the record right: that is `appSheet(item:)`'s `onItemShown`, pinned from
/// the source by `ChatSheetHandOverSourceTests` and run on a stand-in by
/// `MacSheetItemHandOverTests`.
final class ChatSheetDismissalPolicyTests: XCTestCase {
    private let participants = ChatDestination.participants.id
    private let newContact = ChatDestination.addContact(ContactWrapper(contact: CNMutableContact())).id

    /// Revert-check: making `ChatSheetDismissalPolicy.clearsDestinations` return false where
    /// `pendingDestinationID` is nil makes this fail.
    func testClearsDestinations_nothingPending_clears() {
        XCTAssertTrue(
            ChatSheetDismissalPolicy.clearsDestinations(
                pendingDestinationID: nil,
                dismissedDestinationID: participants
            )
        )
        XCTAssertTrue(
            ChatSheetDismissalPolicy.clearsDestinations(pendingDestinationID: nil, dismissedDestinationID: nil)
        )
    }

    /// Cancel or Open in Contacts on the New Contact sheet: the destination waiting is the one
    /// on screen, so the dismissal is its own and clears it.
    ///
    /// Revert-check: making `ChatSheetDismissalPolicy.clearsDestinations` return false whenever
    /// a destination is pending makes this fail.
    func testClearsDestinations_pendingDestinationIsTheOneOnScreen_clears() {
        XCTAssertTrue(
            ChatSheetDismissalPolicy.clearsDestinations(
                pendingDestinationID: newContact,
                dismissedDestinationID: newContact
            )
        )
    }

    /// iOS: Participants' sheet is dismissed with New Contact already the chat's state, and
    /// its `onDismiss` must not clear the contact the next sheet is about to show.
    ///
    /// Revert-check: making `ChatSheetDismissalPolicy.clearsDestinations` return true always
    /// makes this fail.
    func testClearsDestinations_anotherDestinationIsPending_leavesIt() {
        XCTAssertFalse(
            ChatSheetDismissalPolicy.clearsDestinations(
                pendingDestinationID: newContact,
                dismissedDestinationID: participants
            )
        )
    }

    /// A destination set after the last sheet's `onDismiss` cleared the record, and before its
    /// own content has been shown: a dismissal that arrives then is not that destination's.
    ///
    /// Revert-check: making `ChatSheetDismissalPolicy.clearsDestinations` return true where
    /// `dismissedDestinationID` is nil makes this fail.
    func testClearsDestinations_pendingDestinationNotYetShown_leavesIt() {
        XCTAssertFalse(
            ChatSheetDismissalPolicy.clearsDestinations(
                pendingDestinationID: newContact,
                dismissedDestinationID: nil
            )
        )
    }

    /// The Mac's hand-over, event by event as the throwaway program logged it: Participants is
    /// shown, New Contact takes its window with no `onDismiss`, and the sheet's own button asks
    /// to be dismissed. What the rule answers then depends only on whether the hand-over was
    /// recorded.
    ///
    /// Revert-check: making `ChatSheetDismissalPolicy.clearsDestinations` compare nothing and
    /// return `pendingDestinationID == nil` makes the first assertion fail.
    func testClearsDestinations_macHandOver_clearsOnlyWhereTheHandOverWasRecorded() {
        var recordedOnScreen: String? = participants

        // `appSheet(item:)`'s `onItemShown` reports the destination the window was given.
        recordedOnScreen = newContact
        XCTAssertTrue(
            ChatSheetDismissalPolicy.clearsDestinations(
                pendingDestinationID: newContact,
                dismissedDestinationID: recordedOnScreen
            ),
            "The sheet on screen must be able to close"
        )

        // Build 562: nothing reported it, the record still said Participants, and the same
        // press cleared nothing. The rule cannot tell this from iOS's replacement above, which
        // is why the record has to be right.
        XCTAssertFalse(
            ChatSheetDismissalPolicy.clearsDestinations(
                pendingDestinationID: newContact,
                dismissedDestinationID: participants
            )
        )
    }
}
