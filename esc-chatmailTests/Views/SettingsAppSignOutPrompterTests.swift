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

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
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
