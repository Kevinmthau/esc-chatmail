import XCTest
@testable import esc_chatmail

/// Drives `SettingsAppSignOutController` — what a look at the Settings app's
/// Sign Out switch does — with a fake account and prompter.
///
/// HONEST SCOPE: *when* it looks (appear, foreground, window focus, auth
/// change) is `ContentView` wiring, which never mounts in the unit-test host;
/// so is drawing the "Signing Out…" overlay from `isSigningOut`.
@MainActor
final class SettingsAppSignOutControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var preferences: SettingsAppPreferences!
    private var account: FakeAccount!
    private var prompter: FakePrompter!
    private var controller: SettingsAppSignOutController!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsAppSignOutControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = SettingsAppPreferences(defaults: defaults)
        account = FakeAccount()
        prompter = FakePrompter()
        controller = SettingsAppSignOutController(preferences: preferences, prompter: prompter)
    }

    override func tearDown() {
        account.releaseSignOut(returning: true)
        defaults.removePersistentDomain(forName: suiteName)
        controller = nil
        prompter = nil
        account = nil
        preferences = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Evaluation

    /// Only a pending request pays for the keychain-reading durable check,
    /// which otherwise runs on every foregrounding and focus change.
    ///
    /// Revert-check: dropping `isSignOutRequested &&` from the
    /// `isDurablySignedOut:` argument in `SettingsAppSignOutController.evaluate`
    /// makes this fail.
    func testEvaluate_noRequest_neitherPromptsNorReadsDurableState() {
        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(account.isDurablySignedOutCallCount, 0)
        XCTAssertEqual(prompter.confirmationCount, 0)
    }

    /// A retryably failed launch restore (offline with an expired token) shows
    /// `SignInView` with `isAuthenticated == false`, yet the account is still
    /// on the device; the request must reach the confirmation, not be dropped.
    ///
    /// Revert-check: judging the request on `!account.isAuthenticated` instead
    /// of `account.isDurablySignedOut()` in `SettingsAppSignOutController.evaluate`
    /// makes this fail.
    func testEvaluate_requestWhileUnauthenticatedButAccountOnDevice_presentsConfirmation() {
        requestSignOut()
        account.isAuthenticated = false
        account.userEmail = nil
        account.durablySignedOut = false

        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertNil(prompter.lastAccountEmail)
        XCTAssertTrue(preferences.isSignOutRequested, "the request stays pending until the user answers")
    }

    func testEvaluate_requestWhileSignedIn_presentsConfirmationNamingAccount() {
        requestSignOut()

        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertEqual(prompter.lastAccountEmail, "user@example.com")
    }

    /// Revert-check: removing `preferences.clearSignOutRequest()` from the
    /// `.discardRequest` case in `SettingsAppSignOutController.evaluate` makes
    /// this fail.
    func testEvaluate_requestWhileDurablySignedOut_clearsRequestWithoutPrompt() {
        requestSignOut()
        account.durablySignedOut = true

        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertFalse(preferences.isSignOutRequested)
        XCTAssertEqual(prompter.confirmationCount, 0)
    }

    /// Revert-check: dropping `prompter.isConfirmationActive` from
    /// `isRequestBeingHandled` in `SettingsAppSignOutController.evaluate` makes
    /// this fail.
    func testEvaluate_requestWhileConfirmationActive_doesNotStackPrompt() {
        requestSignOut()
        prompter.isConfirmationActive = true

        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.confirmationCount, 0)
        XCTAssertTrue(preferences.isSignOutRequested)
    }

    // MARK: - Answers

    /// Revert-check: removing `clearSignOutRequest()` from the `onCancel`
    /// handler in `SettingsAppSignOutController.evaluate` makes this fail.
    func testCancel_clearsRequestWithoutSigningOut() throws {
        requestSignOut()
        controller.evaluate(account: account, isSceneActive: true)

        try XCTUnwrap(prompter.onCancel)()

        XCTAssertFalse(preferences.isSignOutRequested)
        XCTAssertEqual(account.signOutCallCount, 0)
    }

    /// While the confirmed sign-out is suspended, a further look neither
    /// prompts again nor starts a second `signOut()`, even with the switch
    /// turned on again.
    ///
    /// Revert-check: dropping `isSigningOut` from `isRequestBeingHandled` in
    /// `SettingsAppSignOutController.evaluate` makes this fail.
    func testSignOut_confirmed_clearsRequestAndSignsOutOnce() async throws {
        requestSignOut()
        account.suspendsSignOut = true
        controller.evaluate(account: account, isSceneActive: true)

        try XCTUnwrap(prompter.onSignOut)()
        await waitUntil { self.account.signOutCallCount == 1 }

        XCTAssertFalse(preferences.isSignOutRequested)
        XCTAssertTrue(controller.isSigningOut)
        requestSignOut()
        controller.evaluate(account: account, isSceneActive: true)
        XCTAssertEqual(prompter.confirmationCount, 1)

        account.releaseSignOut(returning: true)
        await waitUntil { !self.controller.isSigningOut }
        XCTAssertEqual(account.signOutCallCount, 1)
        XCTAssertEqual(prompter.failureCount, 0)
    }

    /// The prompt can outlive the session it was raised for; confirming it
    /// then must not run a sign-out with no session to end. The guard returns
    /// before any task starts, so `isSigningOut` staying false is synchronous
    /// proof that no sign-out began.
    ///
    /// Revert-check: removing `!account.isDurablySignedOut()` from the guard in
    /// `SettingsAppSignOutController.signOutConfirmed` makes this fail.
    func testSignOut_confirmedAfterSessionEnded_doesNotSignOut() throws {
        requestSignOut()
        controller.evaluate(account: account, isSceneActive: true)
        account.durablySignedOut = true

        try XCTUnwrap(prompter.onSignOut)()

        XCTAssertFalse(controller.isSigningOut)
        XCTAssertEqual(account.signOutCallCount, 0)
        XCTAssertFalse(preferences.isSignOutRequested)
    }

    /// Revert-check: removing `prompter.presentFailure()` from
    /// `SettingsAppSignOutController.signOutConfirmed` makes this fail.
    func testSignOut_cleanupNeverBegan_presentsFailureAndClearsOverlay() async throws {
        requestSignOut()
        account.signOutResult = false
        controller.evaluate(account: account, isSceneActive: true)

        try XCTUnwrap(prompter.onSignOut)()
        await waitUntil { self.prompter.failureCount == 1 }

        XCTAssertFalse(controller.isSigningOut)
        XCTAssertFalse(preferences.isSignOutRequested, "the user turns the switch on again to retry")
    }

    // MARK: - Menu command

    // HONEST SCOPE: these drive `requestSignOut(account:focusedWindowHasSheet:)` and
    // `refreshHeldAccount(account:)`, what the Mac's Sign Out… menu command calls. The
    // command itself is not exercised: `SignOutCommands`, the focused value `ContentView`
    // publishes for it (`SignOutMenuActionPublisher`), the AppKit read behind
    // `focusedWindowHasSheet` (`FocusedWindowSheet`), the beep on a refusal and the scene's
    // `.commands` need a mounted window and a menu bar, which the unit-test host never has.
    // Nobody has seen the command on screen either.

    /// The Mac has no Settings app page, so the command must ask at once. It must not store
    /// the request: a stored one outlives a force quit made before the alert is answered and
    /// asks again at the next launch, with no switch on screen to explain it.
    ///
    /// Revert-check: writing `signOutRequestedKey` in
    /// `SettingsAppSignOutController.requestSignOut` makes this fail, and so does removing
    /// its `presentConfirmation` call.
    func testRequestSignOut_whileSignedIn_presentsConfirmationWithoutStoringRequest() {
        let choice = controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        XCTAssertEqual(choice, .confirm)
        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertEqual(prompter.lastAccountEmail, "user@example.com")
        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.signOutRequestedKey))
    }

    /// Each window has its own controller and prompter over the same defaults. A request the
    /// command stored would be confirmed again by a second window as soon as it looked.
    ///
    /// Revert-check: writing `signOutRequestedKey` in
    /// `SettingsAppSignOutController.requestSignOut` makes this fail.
    func testRequestSignOut_unanswered_secondWindowsControllerDoesNotPrompt() {
        let secondPrompter = FakePrompter()
        let secondController = SettingsAppSignOutController(preferences: preferences, prompter: secondPrompter)
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        secondController.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertEqual(secondPrompter.confirmationCount, 0)
    }

    /// Under New Message or the reader the alert would stay queued and unseen, so the command
    /// asks nothing there and reports the refusal for its beep.
    ///
    /// Revert-check: passing `focusedWindowHasSheet: false` to `SignOutMenuPolicy.choice` in
    /// `SettingsAppSignOutController.requestSignOut` makes this fail.
    func testRequestSignOut_focusedWindowHasSheet_refusesWithoutPrompt() {
        let choice = controller.requestSignOut(account: account, focusedWindowHasSheet: true)

        XCTAssertEqual(choice, .refuse)
        XCTAssertEqual(prompter.confirmationCount, 0)
        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.signOutRequestedKey))
    }

    /// The command is enabled from a cached answer, so it can be chosen with no session left
    /// to end. It must ask nothing, leave nothing stored, and correct the cache so the command
    /// disables itself.
    ///
    /// Revert-check: passing `isDurablySignedOut: false` to `SettingsAppSignOutPolicy.decision`
    /// in `SettingsAppSignOutController.requestSignOut` makes this fail, and so does removing
    /// its `setHoldsAccountWhileSignedOut` call.
    func testRequestSignOut_whileDurablySignedOut_refusesAndCorrectsHeldAccount() {
        account.isAuthenticated = false
        account.userEmail = nil
        controller.refreshHeldAccount(account: account)
        XCTAssertTrue(controller.holdsAccountWhileSignedOut)
        account.durablySignedOut = true

        let choice = controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        XCTAssertEqual(choice, .refuse)
        XCTAssertEqual(prompter.confirmationCount, 0)
        XCTAssertFalse(preferences.isSignOutRequested)
        XCTAssertFalse(controller.holdsAccountWhileSignedOut)
    }

    /// A retryably failed launch restore leaves the account on the Mac behind `SignInView`;
    /// the command is the Mac's only way to remove it.
    ///
    /// Revert-check: judging the request on `!account.isAuthenticated` instead of
    /// `account.isDurablySignedOut()` in `SettingsAppSignOutController.requestSignOut` makes
    /// this fail.
    func testRequestSignOut_accountHeldBehindSignIn_presentsConfirmation() {
        account.isAuthenticated = false
        account.userEmail = nil
        account.durablySignedOut = false

        let choice = controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        XCTAssertEqual(choice, .confirm)
        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertNil(prompter.lastAccountEmail)
    }

    /// Revert-check: dropping `prompter.isConfirmationActive` from `isRequestBeingHandled` in
    /// `SettingsAppSignOutController.requestSignOut` makes this fail.
    func testRequestSignOut_whileConfirmationActive_refusesWithoutStackingPrompt() {
        prompter.isConfirmationActive = true

        let choice = controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        XCTAssertEqual(choice, .refuse)
        XCTAssertEqual(prompter.confirmationCount, 0)
    }

    /// The whole path the menu command starts: ask, confirm, one `signOut()`, and nothing
    /// stored at any point.
    ///
    /// Revert-check: removing the `presentConfirmation` call from
    /// `SettingsAppSignOutController.requestSignOut` makes this fail (no confirmation is
    /// raised to answer).
    func testRequestSignOut_confirmed_signsOutOnceAndStoresNoRequest() async throws {
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        try XCTUnwrap(prompter.onSignOut)()
        await waitUntil { self.account.signOutCallCount == 1 && !self.controller.isSigningOut }

        XCTAssertEqual(account.signOutCallCount, 1)
        XCTAssertFalse(preferences.isSignOutRequested)
        XCTAssertEqual(prompter.failureCount, 0)
    }

    // MARK: - Held account

    /// While signed in the answer is false without the durable check, which is the read this
    /// cache exists to keep out of a view body.
    ///
    /// Revert-check: dropping `!account.isAuthenticated &&` from
    /// `SettingsAppSignOutController.refreshHeldAccount` makes this fail.
    func testRefreshHeldAccount_signedIn_isFalseWithoutReadingDurableState() {
        controller.refreshHeldAccount(account: account)

        XCTAssertFalse(controller.holdsAccountWhileSignedOut)
        XCTAssertEqual(account.isDurablySignedOutCallCount, 0)
    }

    /// Revert-check: removing the `setHoldsAccountWhileSignedOut` call from
    /// `SettingsAppSignOutController.refreshHeldAccount` makes this fail.
    func testRefreshHeldAccount_signedOutButAccountOnDevice_isTrue() {
        account.isAuthenticated = false
        account.userEmail = nil
        account.durablySignedOut = false

        controller.refreshHeldAccount(account: account)

        XCTAssertTrue(controller.holdsAccountWhileSignedOut)
    }

    /// Revert-check: dropping `&& !account.isDurablySignedOut()` from
    /// `SettingsAppSignOutController.refreshHeldAccount` makes this fail.
    func testRefreshHeldAccount_durablySignedOut_isFalse() {
        account.isAuthenticated = false
        account.userEmail = nil
        account.durablySignedOut = true

        controller.refreshHeldAccount(account: account)

        XCTAssertFalse(controller.holdsAccountWhileSignedOut)
    }

    /// The answer follows the account: held behind `SignInView`, then signed in again.
    ///
    /// Revert-check: making `SettingsAppSignOutController.setHoldsAccountWhileSignedOut` ignore
    /// a change to false makes this fail.
    func testRefreshHeldAccount_afterSigningInAgain_turnsFalse() {
        account.isAuthenticated = false
        controller.refreshHeldAccount(account: account)
        XCTAssertTrue(controller.holdsAccountWhileSignedOut)

        account.isAuthenticated = true
        controller.refreshHeldAccount(account: account)

        XCTAssertFalse(controller.holdsAccountWhileSignedOut)
    }

    // MARK: - Platform prompter

    /// iOS keeps the UIKit prompter, which presents over any sheet; a SwiftUI alert on the root
    /// view would never appear while one is up. So the iOS default must expose no SwiftUI-alert
    /// prompter for `ContentView` to host.
    ///
    /// Revert-check: pointing `PlatformSettingsAppSignOutPrompter` at
    /// `SettingsAppSignOutAlertPrompter` on iOS makes this fail.
    func testDefaultPrompter_onIOS_isUIKitPrompter() {
        let defaultController = SettingsAppSignOutController(preferences: preferences)

        XCTAssertNil(defaultController.alertPrompter)
    }

    /// The Mac's SwiftUI-alert prompter is exposed so `ContentView` can show its alerts, and a
    /// request raised through the controller reaches it.
    ///
    /// Revert-check: making `SettingsAppSignOutController.alertPrompter` return nil makes this fail.
    func testAlertPrompter_injected_isExposedAndReceivesConfirmation() throws {
        let alertPrompter = SettingsAppSignOutAlertPrompter()
        let alertController = SettingsAppSignOutController(preferences: preferences, prompter: alertPrompter)
        requestSignOut()

        alertController.evaluate(account: account, isSceneActive: true)

        XCTAssertTrue(try XCTUnwrap(alertController.alertPrompter) === alertPrompter)
        XCTAssertTrue(alertPrompter.isConfirmationActive)
    }

    // MARK: - Helpers

    private func requestSignOut() {
        defaults.set(true, forKey: SettingsAppPreferences.signOutRequestedKey)
    }

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

@MainActor
private final class FakeAccount: SettingsAppSignOutAccount {
    var isAuthenticated = true
    var userEmail: String? = "user@example.com"
    var durablySignedOut = false
    var signOutResult = true
    var suspendsSignOut = false
    private(set) var isDurablySignedOutCallCount = 0
    private(set) var signOutCallCount = 0
    private var pendingSignOut: CheckedContinuation<Bool, Never>?

    func isDurablySignedOut() -> Bool {
        isDurablySignedOutCallCount += 1
        return durablySignedOut
    }

    func signOut() async -> Bool {
        signOutCallCount += 1
        guard suspendsSignOut else { return signOutResult }
        return await withCheckedContinuation { pendingSignOut = $0 }
    }

    func releaseSignOut(returning result: Bool) {
        pendingSignOut?.resume(returning: result)
        pendingSignOut = nil
    }
}

@MainActor
private final class FakePrompter: SettingsAppSignOutPrompting {
    var isConfirmationActive = false
    private(set) var confirmationCount = 0
    private(set) var failureCount = 0
    private(set) var lastAccountEmail: String?
    private(set) var onSignOut: (() -> Void)?
    private(set) var onCancel: (() -> Void)?

    func presentConfirmation(
        accountEmail: String?,
        onSignOut: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        confirmationCount += 1
        lastAccountEmail = accountEmail
        self.onSignOut = onSignOut
        self.onCancel = onCancel
    }

    func presentFailure() {
        failureCount += 1
    }
}
