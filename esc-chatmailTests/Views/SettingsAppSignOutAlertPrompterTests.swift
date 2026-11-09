import XCTest
@testable import esc_chatmail

/// `SettingsAppSignOutAlertPrompter` is the Mac's Settings-app sign-out prompt. Its code is
/// platform-neutral, so it is pinned here on iOS. As with the UIKit prompter
/// (`SettingsAppSignOutPrompterTests`), `isConfirmationActive` holds every later prompt back
/// while it reads true, so each way an alert can end must release it, and exactly one handler
/// may run per answer.
///
/// HONEST SCOPE: the SwiftUI alert itself (`SettingsAppSignOutAlertModifier`) only mounts in a
/// Mac window, which the iOS-only test target cannot host; these drive the calls its buttons and
/// binding make.
@MainActor
final class SettingsAppSignOutAlertPrompterTests: XCTestCase {
    /// Revert-check: removing `guard !isConfirmationActive` from
    /// `SettingsAppSignOutAlertPrompter.presentConfirmation` makes this fail.
    func testPresentConfirmation_whileConfirmationActive_keepsFirstAlert() throws {
        let prompter = SettingsAppSignOutAlertPrompter()

        prompter.presentConfirmation(accountEmail: "first@example.com", onSignOut: {}, onCancel: {})
        let first = try XCTUnwrap(prompter.alert)
        prompter.presentConfirmation(accountEmail: "second@example.com", onSignOut: {}, onCancel: {})

        XCTAssertTrue(prompter.isConfirmationActive)
        XCTAssertEqual(prompter.alert?.id, first.id)
        XCTAssertEqual(prompter.alert?.kind, .confirmation(accountEmail: "first@example.com"))
    }

    /// Revert-check: swapping the `signOut` branches in `SettingsAppSignOutAlertPrompter.answer`,
    /// or dropping its `alert = nil`, makes this fail.
    func testAnswer_signOut_runsOnlySignOutHandlerAndReleasesGate() throws {
        let prompter = SettingsAppSignOutAlertPrompter()
        var signOutCount = 0
        var cancelCount = 0
        prompter.presentConfirmation(
            accountEmail: nil,
            onSignOut: { signOutCount += 1 },
            onCancel: { cancelCount += 1 }
        )
        let alert = try XCTUnwrap(prompter.alert)

        prompter.answer(alert, signOut: true)

        XCTAssertEqual(signOutCount, 1)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertNil(prompter.alert)
        XCTAssertFalse(prompter.isConfirmationActive)
    }

    /// Revert-check: swapping the `signOut` branches in `SettingsAppSignOutAlertPrompter.answer`
    /// makes this fail.
    func testAnswer_cancel_runsOnlyCancelHandler() throws {
        let prompter = SettingsAppSignOutAlertPrompter()
        var signOutCount = 0
        var cancelCount = 0
        prompter.presentConfirmation(
            accountEmail: nil,
            onSignOut: { signOutCount += 1 },
            onCancel: { cancelCount += 1 }
        )
        let alert = try XCTUnwrap(prompter.alert)

        prompter.answer(alert, signOut: false)

        XCTAssertEqual(signOutCount, 0)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(prompter.isConfirmationActive)
    }

    /// SwiftUI may clear the alert through its binding before the tapped button's action runs;
    /// the answer must still reach its handler, or a confirmed sign-out would silently not start.
    ///
    /// Revert-check: guarding the handler calls in `SettingsAppSignOutAlertPrompter.answer` on
    /// `alert?.id == answered.id` makes this fail.
    func testAnswer_afterBindingAlreadyDismissedAlert_stillRunsHandler() throws {
        let prompter = SettingsAppSignOutAlertPrompter()
        var signOutCount = 0
        prompter.presentConfirmation(accountEmail: nil, onSignOut: { signOutCount += 1 }, onCancel: {})
        let alert = try XCTUnwrap(prompter.alert)

        prompter.alertDidDismiss(alert)
        prompter.answer(alert, signOut: true)

        XCTAssertEqual(signOutCount, 1)
    }

    /// An alert torn down unanswered runs neither handler and releases the gate, so the request
    /// is asked about again on the next look.
    ///
    /// Revert-check: removing `alert = nil` from `SettingsAppSignOutAlertPrompter.alertDidDismiss`
    /// makes this fail.
    func testAlertDidDismiss_unanswered_runsNoHandlerAndReleasesGate() throws {
        let prompter = SettingsAppSignOutAlertPrompter()
        var handlerCount = 0
        prompter.presentConfirmation(
            accountEmail: nil,
            onSignOut: { handlerCount += 1 },
            onCancel: { handlerCount += 1 }
        )
        let alert = try XCTUnwrap(prompter.alert)

        prompter.alertDidDismiss(alert)

        XCTAssertEqual(handlerCount, 0)
        XCTAssertFalse(prompter.isConfirmationActive)
        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})
        XCTAssertNotNil(prompter.alert)
    }

    /// A late dismissal of an alert that was already replaced must not clear its replacement.
    ///
    /// Revert-check: removing `guard alert?.id == dismissed.id` from
    /// `SettingsAppSignOutAlertPrompter.alertDidDismiss` makes this fail.
    func testAlertDidDismiss_staleAlert_keepsNewerAlert() throws {
        let prompter = SettingsAppSignOutAlertPrompter()
        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})
        let stale = try XCTUnwrap(prompter.alert)
        prompter.answer(stale, signOut: false)
        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})
        let current = try XCTUnwrap(prompter.alert)

        prompter.alertDidDismiss(stale)

        XCTAssertEqual(prompter.alert?.id, current.id)
        XCTAssertTrue(prompter.isConfirmationActive)
    }

    /// The failure alert is not a confirmation, so it never holds a later request back.
    ///
    /// Revert-check: making `SettingsAppSignOutAlertPrompter.isConfirmationActive` read
    /// `alert != nil` makes this fail.
    func testPresentFailure_doesNotHoldConfirmationGate() {
        let prompter = SettingsAppSignOutAlertPrompter()

        prompter.presentFailure()

        XCTAssertEqual(prompter.alert?.kind, .failure)
        XCTAssertFalse(prompter.isConfirmationActive)
    }

    /// The confirmation names the account it signs out, as the UIKit prompt does.
    func testConfirmationMessage_namesAccountOrFallsBack() {
        let prompter = SettingsAppSignOutAlertPrompter()

        prompter.presentConfirmation(accountEmail: "user@example.com", onSignOut: {}, onCancel: {})
        XCTAssertEqual(prompter.alert?.title, "Sign Out of MushMail?")
        XCTAssertEqual(
            prompter.alert?.message,
            "user@example.com will be signed out and its mail removed from this device."
        )

        prompter.alertDidDismiss(prompter.alert!)
        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})
        XCTAssertEqual(
            prompter.alert?.message,
            "This account will be signed out and its mail removed from this device."
        )
    }
}
