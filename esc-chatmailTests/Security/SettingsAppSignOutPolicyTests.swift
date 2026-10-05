import XCTest
@testable import esc_chatmail

/// HONEST SCOPE: `ContentView`, which feeds this policy, never mounts in the
/// unit-test host (`initializeApp()` no-ops there), and the confirmation is a
/// UIKit alert, so the wiring itself — evaluating on appear/foreground/auth
/// change and acting on each decision — is covered only through this policy
/// and `SettingsAppPreferencesTests`.
final class SettingsAppSignOutPolicyTests: XCTestCase {
    private typealias Policy = SettingsAppSignOutPolicy

    private func decision(
        isSignOutRequested: Bool = true,
        isAuthenticated: Bool = true,
        isRequestBeingHandled: Bool = false,
        isSceneActive: Bool = true
    ) -> Policy.Decision {
        Policy.decision(
            isSignOutRequested: isSignOutRequested,
            isAuthenticated: isAuthenticated,
            isRequestBeingHandled: isRequestBeingHandled,
            isSceneActive: isSceneActive
        )
    }

    func testDecision_noRequest_returnsNoneForEveryOtherInput() {
        for isAuthenticated in [false, true] {
            for isRequestBeingHandled in [false, true] {
                for isSceneActive in [false, true] {
                    XCTAssertEqual(
                        decision(
                            isSignOutRequested: false,
                            isAuthenticated: isAuthenticated,
                            isRequestBeingHandled: isRequestBeingHandled,
                            isSceneActive: isSceneActive
                        ),
                        .none,
                        "authenticated: \(isAuthenticated), handled: \(isRequestBeingHandled), active: \(isSceneActive)"
                    )
                }
            }
        }
    }

    func testDecision_requestWhileAuthenticatedAndActive_returnsConfirm() {
        XCTAssertEqual(decision(), .confirm)
    }

    /// No AuthSession teardown path clears the Settings key, so a switch left
    /// on while signed out would prompt right after the next sign-in.
    ///
    /// Revert-check: removing the `isAuthenticated` guard in
    /// `SettingsAppSignOutPolicy.decision` makes this fail.
    func testDecision_requestWhileSignedOut_discardsRequest() {
        XCTAssertEqual(decision(isAuthenticated: false), .discardRequest)
        XCTAssertEqual(decision(isAuthenticated: false, isSceneActive: false), .discardRequest)
    }

    /// A switch turned on again while a confirmed sign-out finishes its
    /// cleanup (session already ended, request still being handled) is
    /// dropped instead of surviving into the next account's session.
    func testDecision_requestWhileHandledSignOutHasEndedSession_discardsRequest() {
        XCTAssertEqual(decision(isAuthenticated: false, isRequestBeingHandled: true), .discardRequest)
    }

    /// Returning to the foreground again while the prompt is up (or the
    /// sign-out runs) must not stack a second prompt or a second `signOut()`.
    ///
    /// Revert-check: removing `!isRequestBeingHandled` from
    /// `SettingsAppSignOutPolicy.decision` makes this fail.
    func testDecision_requestWhileBeingHandled_returnsNone() {
        XCTAssertEqual(decision(isRequestBeingHandled: true), .none)
    }

    /// A background launch must not present UI; the request waits for the
    /// next foregrounding rather than being discarded.
    ///
    /// Revert-check: removing `isSceneActive` from
    /// `SettingsAppSignOutPolicy.decision` makes this fail.
    func testDecision_requestWhileSceneInactive_returnsNone() {
        XCTAssertEqual(decision(isSceneActive: false), .none)
    }
}
