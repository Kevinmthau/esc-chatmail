#if os(iOS)
import XCTest
import UIKit
@testable import esc_chatmail

/// `SettingsAppSignOutPrompter.isConfirmationActive` holds every later
/// Settings-app sign-out prompt back while it reads true, and the Settings
/// app's switch is the only way to sign out; these pin that it releases on
/// each way a confirmation can end without an answer.
@MainActor
final class SettingsAppSignOutPrompterTests: XCTestCase {
    /// While the presenter is still looking for a controller the gate holds,
    /// so a second look cannot stack a prompt; once it gives up the gate
    /// releases, so the request is asked about again on the next look. The
    /// stacked call would present from its own task, so the count is checked
    /// only after the waits that let such a task run.
    ///
    /// Revert-check: removing `self.isAwaitingPresenter = false` from
    /// `SettingsAppSignOutPrompter.presentConfirmation` makes this fail, and so
    /// does removing its `guard !isConfirmationActive`.
    func testPresentConfirmation_presenterGivesUp_releasesConfirmationGate() async {
        let presenter = SuspendedPresenter()
        let prompter = SettingsAppSignOutPrompter(present: presenter.present)

        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})
        await waitUntil { presenter.hasPendingCall }

        XCTAssertTrue(prompter.isConfirmationActive)
        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})

        presenter.finishPendingCall(returning: false)
        await waitUntil { !prompter.isConfirmationActive }
        XCTAssertEqual(presenter.callCount, 1, "a call while the gate held must not have presented")

        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})
        await waitUntil { presenter.callCount == 2 }
        presenter.finishPendingCall(returning: false)
    }

    /// An alert torn down unanswered (e.g. with the sheet it was shown over)
    /// calls neither action handler, so only the alert's own presentation
    /// state can report that it is gone.
    ///
    /// Revert-check: holding `presentedAlert` strongly and reading
    /// `presentedAlert != nil` in place of its `presentingViewController` in
    /// `SettingsAppSignOutPrompter.isConfirmationActive` makes this fail.
    func testPresentConfirmation_alertDismissedUnanswered_releasesConfirmationGate() async throws {
        let window = try makeTestHostWindow()
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var wasAnswered = false
        let prompter = SettingsAppSignOutPrompter(present: { alert in
            root.present(alert, animated: false)
            return true
        })

        prompter.presentConfirmation(
            accountEmail: "user@example.com",
            onSignOut: { wasAnswered = true },
            onCancel: { wasAnswered = true }
        )
        await waitUntil { root.presentedViewController is UIAlertController }
        XCTAssertTrue(prompter.isConfirmationActive)

        root.dismiss(animated: false)
        await waitUntil { !prompter.isConfirmationActive }

        XCTAssertFalse(wasAnswered)
    }

    /// A confirmation whose session changed is taken down, and the one asked in the same
    /// turn (`SettingsAppSignOutController.evaluate` asks again at once) is the alert on
    /// screen afterwards. Shown in a real window, so this is UIKit presenting one alert
    /// straight after dismissing another, which it does once the first is up.
    ///
    /// Revert-check: removing `alert.dismiss(animated: false)` from
    /// `SettingsAppSignOutPrompter.withdrawConfirmation` makes this fail: the first alert
    /// stays up and the second is never presented. So does removing its
    /// `presentedAlert = nil`: the alert still has its presenter when `dismiss` returns, so
    /// the gate reads held and the second confirmation is never asked.
    func testWithdrawConfirmation_takesTheAlertDown_andTheNextOneIsPresented() async throws {
        let window = try makeTestHostWindow()
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        var handlerCount = 0
        let prompter = SettingsAppSignOutPrompter(present: { alert in
            root.present(alert, animated: false)
            return true
        })
        prompter.presentConfirmation(
            accountEmail: nil,
            onSignOut: { handlerCount += 1 },
            onCancel: { handlerCount += 1 }
        )
        // Up, and not still coming up: an alert withdrawn before that is left for the next
        // look (the test after this one).
        await waitUntil {
            prompter.isConfirmationActive
                && (root.presentedViewController as? UIAlertController)?.isBeingPresented == false
        }

        prompter.withdrawConfirmation()
        XCTAssertFalse(prompter.isConfirmationActive, "the gate must be open when the call returns")
        prompter.presentConfirmation(accountEmail: "restored@example.com", onSignOut: {}, onCancel: {})

        await waitUntil {
            (root.presentedViewController as? UIAlertController)?.message?.contains("restored@example.com") == true
        }
        XCTAssertTrue(prompter.isConfirmationActive)
        XCTAssertEqual(handlerCount, 0)
    }

    /// UIKit puts off a dismissal asked for while the alert is still coming up, and the
    /// confirmation asked next was then presented with the first still up, and lost. So an
    /// alert that is still coming up is left, with the gate held, for the next look.
    ///
    /// The window's layer is slowed so that the alert is still coming up when the test
    /// looks, however late it looks.
    ///
    /// Revert-check: dropping `!alert.isBeingPresented` from the guard in
    /// `SettingsAppSignOutPrompter.withdrawConfirmation` makes this fail.
    func testWithdrawConfirmation_alertStillComingUp_leavesItWithTheGateHeld() async throws {
        let window = try makeTestHostWindow()
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layer.speed = 0.02
        defer {
            window.layer.speed = 1
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        let prompter = SettingsAppSignOutPrompter(present: { alert in
            root.present(alert, animated: true)
            return true
        })
        prompter.presentConfirmation(accountEmail: "first@example.com", onSignOut: {}, onCancel: {})
        await waitUntil { prompter.isConfirmationActive && root.presentedViewController is UIAlertController }
        let alert = try XCTUnwrap(root.presentedViewController as? UIAlertController)
        XCTAssertTrue(alert.isBeingPresented, "the alert must still be coming up for this to test anything")

        prompter.withdrawConfirmation()

        XCTAssertTrue(prompter.isConfirmationActive)
        XCTAssertTrue(root.presentedViewController === alert)
        XCTAssertFalse(alert.isBeingDismissed)
    }

    /// A confirmation still waiting for a presenter has no alert on screen to take down. The
    /// gate stays held, or a second confirmation asked now would be presented beside the
    /// first when both found a presenter.
    ///
    /// Revert-check: clearing `isAwaitingPresenter` in
    /// `SettingsAppSignOutPrompter.withdrawConfirmation` makes this fail.
    func testWithdrawConfirmation_whileWaitingForAPresenter_keepsTheGateHeld() async {
        let presenter = SuspendedPresenter()
        let prompter = SettingsAppSignOutPrompter(present: presenter.present)
        prompter.presentConfirmation(accountEmail: nil, onSignOut: {}, onCancel: {})
        await waitUntil { presenter.hasPendingCall }

        prompter.withdrawConfirmation()

        XCTAssertTrue(prompter.isConfirmationActive)
        presenter.finishPendingCall(returning: false)
        await waitUntil { !prompter.isConfirmationActive }
    }


    // MARK: - Helpers

    /// Polls `condition` until it holds or `timeout` elapses. The condition is
    /// checked before the deadline on every pass, so a main-thread stall longer
    /// than the timeout cannot fail a condition that came true during the stall.
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

/// A presenter that never finds a controller until the test says so.
@MainActor
private final class SuspendedPresenter {
    private(set) var callCount = 0
    private var pendingCall: CheckedContinuation<Bool, Never>?

    var hasPendingCall: Bool { pendingCall != nil }

    func present(_ viewController: UIViewController) async -> Bool {
        callCount += 1
        return await withCheckedContinuation { pendingCall = $0 }
    }

    func finishPendingCall(returning didPresent: Bool) {
        pendingCall?.resume(returning: didPresent)
        pendingCall = nil
    }
}
#endif
