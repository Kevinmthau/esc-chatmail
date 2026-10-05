import XCTest
@testable import esc_chatmail

/// Acting on each decision, and which session signal feeds it, is pinned by
/// `SettingsAppSignOutControllerTests`; when a look happens is `ContentView`
/// wiring that no test exercises (see the HONEST SCOPE note there).
final class SettingsAppSignOutPolicyTests: XCTestCase {
    private typealias Policy = SettingsAppSignOutPolicy

    private func decision(
        isSignOutRequested: Bool = true,
        isDurablySignedOut: Bool = false,
        isRequestBeingHandled: Bool = false,
        isSceneActive: Bool = true
    ) -> Policy.Decision {
        Policy.decision(
            isSignOutRequested: isSignOutRequested,
            isDurablySignedOut: isDurablySignedOut,
            isRequestBeingHandled: isRequestBeingHandled,
            isSceneActive: isSceneActive
        )
    }

    func testDecision_noRequest_returnsNoneForEveryOtherInput() {
        for isDurablySignedOut in [false, true] {
            for isRequestBeingHandled in [false, true] {
                for isSceneActive in [false, true] {
                    XCTAssertEqual(
                        decision(
                            isSignOutRequested: false,
                            isDurablySignedOut: isDurablySignedOut,
                            isRequestBeingHandled: isRequestBeingHandled,
                            isSceneActive: isSceneActive
                        ),
                        .none,
                        "signedOut: \(isDurablySignedOut), handled: \(isRequestBeingHandled), active: \(isSceneActive)"
                    )
                }
            }
        }
    }

    /// Covers a signed-in mailbox, and equally a reauthentication-pending
    /// session or a retryably failed launch restore: `SignInView` shows in
    /// both, yet the account (credentials, store, bodies) is still on the
    /// device, so the request must reach the confirmation rather than be
    /// dropped while nothing was removed.
    ///
    /// This pins the policy's answer for that input. That the input is
    /// `isDurablySignedOut()` rather than `!isAuthenticated` (the signal that
    /// dropped requests after a retryable restore) is pinned by
    /// `SettingsAppSignOutControllerTests.testEvaluate_requestWhileUnauthenticatedButAccountOnDevice_presentsConfirmation`.
    func testDecision_requestWhileAccountRemainsOnDevice_returnsConfirm() {
        XCTAssertEqual(decision(isDurablySignedOut: false), .confirm)
    }

    /// No AuthSession teardown path clears the Settings key, so a switch left
    /// on while signed out would prompt right after the next sign-in.
    ///
    /// Revert-check: removing the `isDurablySignedOut` guard in
    /// `SettingsAppSignOutPolicy.decision` makes this fail.
    func testDecision_requestWhileDurablySignedOut_discardsRequest() {
        XCTAssertEqual(decision(isDurablySignedOut: true), .discardRequest)
        XCTAssertEqual(decision(isDurablySignedOut: true, isSceneActive: false), .discardRequest)
    }

    /// A switch turned on again while a confirmed sign-out is still cleaning
    /// up (already durably signed out, request still being handled) is dropped
    /// instead of surviving into the next account's session.
    ///
    /// Revert-check: moving the `isDurablySignedOut` guard after the
    /// `isRequestBeingHandled` guard in `SettingsAppSignOutPolicy.decision`
    /// makes this fail.
    func testDecision_requestWhileHandledSignOutIsCleaningUp_discardsRequest() {
        XCTAssertEqual(decision(isDurablySignedOut: true, isRequestBeingHandled: true), .discardRequest)
    }

    /// Another evaluation while the prompt is up (or the sign-out runs) must
    /// not stack a second prompt or a second `signOut()`.
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
