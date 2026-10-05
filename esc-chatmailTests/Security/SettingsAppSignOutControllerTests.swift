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

    // MARK: - Helpers

    private func requestSignOut() {
        defaults.set(true, forKey: SettingsAppPreferences.signOutRequestedKey)
    }

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
