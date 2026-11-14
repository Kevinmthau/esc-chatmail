import Combine
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
    /// The test's own, so a sign-out left running by one test is not another's.
    private var activity: SettingsAppSignOutActivity!
    private var controller: SettingsAppSignOutController!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsAppSignOutControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = SettingsAppPreferences(defaults: defaults)
        account = FakeAccount()
        prompter = FakePrompter()
        activity = SettingsAppSignOutActivity()
        controller = SettingsAppSignOutController(preferences: preferences, prompter: prompter, activity: activity)
    }

    override func tearDown() {
        account.releaseSignOut(returning: true)
        defaults.removePersistentDomain(forName: suiteName)
        controller = nil
        activity = nil
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
    /// handler in `SettingsAppSignOutController.presentConfirmation` makes this
    /// fail.
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

    /// Revert-check: dropping `activity.isConfirmationActiveInAnyWindow()` from
    /// `isRequestBeingHandled` in `SettingsAppSignOutController.requestSignOut` makes this fail.
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

    // MARK: - Two windows

    // HONEST SCOPE: the two windows are two controllers sharing one
    // `SettingsAppSignOutActivity`, as the Mac's mailbox and Settings windows do. That the
    // Sign Out… command and button read `isAnySignOutRunning` is `SignOutMenuAction`'s, and
    // that the Settings window reports whether it is on screen is `MacSettingsView` wiring
    // (`MacSettingsSceneSourceTests`, `MacWindowVisibilityProbeTests`). Nobody has seen
    // either on screen.

    /// A sign-out started in one window disables Sign Out… in the other, which read as
    /// enabled before and beeped when chosen.
    ///
    /// Revert-check: removing `activity.signOutDidBegin()` from
    /// `SettingsAppSignOutController.signOutConfirmed` makes this fail, and so does dropping
    /// `|| activity.isSigningOut` from `isAnySignOutRunning`.
    func testIsAnySignOutRunning_anotherWindowsSignOut_isTrueUntilItEnds() async throws {
        let other = makeOtherWindowsController()
        account.suspendsSignOut = true
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        try XCTUnwrap(prompter.onSignOut)()
        await waitUntil { self.account.signOutCallCount == 1 }

        XCTAssertTrue(controller.isAnySignOutRunning)
        XCTAssertTrue(other.controller.isAnySignOutRunning)
        XCTAssertFalse(other.controller.isSigningOut, "the progress is drawn by the window that started it")

        account.releaseSignOut(returning: true)
        await waitUntil { !self.controller.isSigningOut }

        // Revert-check: removing `activity.signOutDidEnd()` from
        // `SettingsAppSignOutController.signOutConfirmed` makes these fail: Sign Out… would
        // stay disabled in every window until the app is quit.
        XCTAssertFalse(controller.isAnySignOutRunning)
        XCTAssertFalse(other.controller.isAnySignOutRunning)
    }

    /// The other window's command is drawn from its own controller, so that controller must
    /// publish when the shared answer changes.
    ///
    /// Revert-check: removing the `activity.objectWillChange.sink` from
    /// `SettingsAppSignOutController.init` makes this fail: the other window's Sign Out…
    /// would keep the state it was last drawn with.
    func testAnotherWindowsSignOut_republishesThisWindowsController() async throws {
        let other = makeOtherWindowsController()
        var otherPublishCount = 0
        let observation = other.controller.objectWillChange.sink { otherPublishCount += 1 }
        defer { observation.cancel() }
        account.suspendsSignOut = true
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        try XCTUnwrap(prompter.onSignOut)()
        XCTAssertEqual(otherPublishCount, 1)

        await waitUntil { self.account.signOutCallCount == 1 }
        account.releaseSignOut(returning: true)
        await waitUntil { !self.controller.isSigningOut }
        XCTAssertEqual(otherPublishCount, 2)
    }

    /// The Mac's Settings window can be closed while its sign-out runs. Its failure alert
    /// would wait there unseen, with the mailbox still signed in and nothing said.
    ///
    /// Revert-check: calling `prompter.presentFailure()` unconditionally from
    /// `SettingsAppSignOutController.presentFailure` makes this fail.
    func testSignOut_cleanupNeverBegan_windowOffScreen_showsFailureInFallbackWindow() async throws {
        let mailbox = makeOtherWindowsController(showsFailuresOfOffScreenWindows: true)
        controller.setAlertHost(isOnScreen: { false })
        account.signOutResult = false
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        try XCTUnwrap(prompter.onSignOut)()
        await waitUntil { mailbox.prompter.failureCount == 1 }

        XCTAssertEqual(prompter.failureCount, 0)
        XCTAssertFalse(controller.isAnySignOutRunning)
    }

    /// Revert-check: dropping `!alertHostIsOnScreen()` from
    /// `SettingsAppSignOutController.presentFailure` makes this fail: the failure would come
    /// up on the mailbox window, behind the Settings window that asked.
    func testSignOut_cleanupNeverBegan_windowOnScreen_showsFailureInItsOwnWindow() async throws {
        let mailbox = makeOtherWindowsController(showsFailuresOfOffScreenWindows: true)
        controller.setAlertHost(isOnScreen: { true })
        account.signOutResult = false
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        try XCTUnwrap(prompter.onSignOut)()
        await waitUntil { self.prompter.failureCount == 1 }

        XCTAssertEqual(mailbox.prompter.failureCount, 0)
    }

    /// With no window to take it, the failure is still raised in its own window, and shows
    /// when that window is next opened: no worse than before there was a fallback.
    ///
    /// Revert-check: returning from `SettingsAppSignOutController.presentFailure` whenever
    /// `alertHostIsOnScreen()` is false, without asking what
    /// `activity.showFailureInFallbackWindow()` did, makes this fail.
    func testSignOut_cleanupNeverBegan_windowOffScreenAndNoFallback_showsFailureInItsOwnWindow() async throws {
        let other = makeOtherWindowsController(showsFailuresOfOffScreenWindows: false)
        controller.setAlertHost(isOnScreen: { false })
        account.signOutResult = false
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        try XCTUnwrap(prompter.onSignOut)()
        await waitUntil { self.prompter.failureCount == 1 }

        XCTAssertEqual(other.prompter.failureCount, 0)
    }

    /// The fallback is named weakly: a mailbox controller that has gone must not be kept
    /// alive by the activity, and a failure handed to it is not taken as shown.
    ///
    /// Revert-check: capturing `self` strongly in the `setFailureFallback` closure in
    /// `SettingsAppSignOutController.init` makes this fail.
    func testFailureFallback_controllerReleased_showsNothingAndIsNotKept() {
        weak var weakFallback: SettingsAppSignOutController?
        autoreleasepool {
            let fallback = SettingsAppSignOutController(
                preferences: preferences,
                prompter: FakePrompter(),
                activity: activity,
                showsFailuresOfOffScreenWindows: true
            )
            weakFallback = fallback
        }

        XCTAssertNil(weakFallback)
        XCTAssertFalse(activity.showFailureInFallbackWindow())
    }

    /// With the Settings window's confirmation up, Sign Out… chosen with the mailbox window
    /// in front asked again. The first alert outlived the second one's sign-out, and after a
    /// new sign-in it named the old account and signed the new one out.
    ///
    /// Revert-check: passing `isSigningOut || prompter.isConfirmationActive` as
    /// `isRequestBeingHandled` in `SettingsAppSignOutController.requestSignOut` makes this
    /// fail.
    func testRequestSignOut_anotherWindowsConfirmationUp_refusesWithoutPrompt() {
        let other = makeOtherWindowsController()
        other.prompter.isConfirmationActive = true

        let choice = controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        XCTAssertEqual(choice, .refuse)
        XCTAssertEqual(prompter.confirmationCount, 0)

        // Asked again each time, never kept: once the other window's alert has gone, by an
        // answer or with neither handler run, this window can ask.
        other.prompter.isConfirmationActive = false
        XCTAssertEqual(controller.requestSignOut(account: account, focusedWindowHasSheet: false), .confirm)
        XCTAssertEqual(prompter.confirmationCount, 1)
    }

    /// A closed window's controller must not go on refusing the other window's Sign Out…,
    /// whatever its prompter last said.
    ///
    /// Revert-check: capturing `self` strongly in the `addConfirmationSource` closure in
    /// `SettingsAppSignOutController.init` makes this fail.
    func testRequestSignOut_otherWindowsControllerReleased_itsConfirmationIsForgotten() {
        let otherPrompter = FakePrompter()
        otherPrompter.isConfirmationActive = true
        weak var weakOther: SettingsAppSignOutController?
        autoreleasepool {
            let other = SettingsAppSignOutController(
                preferences: preferences,
                prompter: otherPrompter,
                activity: activity
            )
            weakOther = other
        }

        XCTAssertNil(weakOther)
        XCTAssertEqual(controller.requestSignOut(account: account, focusedWindowHasSheet: false), .confirm)
    }

    /// The iOS switch is judged without a look at other windows, as before: a request passed
    /// over there would wait for the next foregrounding.
    ///
    /// Revert-check: passing `activity.isConfirmationActiveInAnyWindow()` in
    /// `isRequestBeingHandled` in `SettingsAppSignOutController.evaluate` makes this fail.
    func testEvaluate_anotherWindowsConfirmationUp_stillPrompts() {
        let other = makeOtherWindowsController()
        other.prompter.isConfirmationActive = true
        requestSignOut()

        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.confirmationCount, 1)
    }

    /// The Settings window's confirmation does not block the mailbox window, so New Message
    /// can be opened there after Sign Out… was chosen. The window is asked again when the
    /// user answers Sign Out.
    ///
    /// Revert-check: removing the `guard !refusesConfirmedSignOut()` from
    /// `SettingsAppSignOutController.signOutConfirmed` makes this fail: the sign-out would
    /// close New Message on the mailbox window with the typed message in it.
    func testSignOutConfirmed_windowRefuses_startsNoSignOut() async throws {
        var refuses = false
        var askedCount = 0
        let settings = makeSettingsWindowsController {
            askedCount += 1
            return refuses
        }
        settings.controller.requestSignOut(account: account, focusedWindowHasSheet: false)
        XCTAssertEqual(askedCount, 0, "asked when the user answers, not when Sign Out… is chosen")
        refuses = true

        try XCTUnwrap(settings.prompter.onSignOut)()

        XCTAssertEqual(askedCount, 1)
        XCTAssertFalse(settings.controller.isSigningOut)
        XCTAssertFalse(settings.controller.isAnySignOutRunning)
        XCTAssertEqual(settings.prompter.failureCount, 0)

        // Refused, not stuck: asked and answered again with nothing in the way, it signs out.
        refuses = false
        settings.controller.requestSignOut(account: account, focusedWindowHasSheet: false)
        try XCTUnwrap(settings.prompter.onSignOut)()
        await waitUntil { self.account.signOutCallCount == 1 }
        XCTAssertEqual(askedCount, 2)
    }

    /// The window is asked, and beeps, only when there was a sign-out to refuse.
    ///
    /// Revert-check: moving the `guard !refusesConfirmedSignOut()` above the
    /// `isDurablySignedOut()` guard in `SettingsAppSignOutController.signOutConfirmed` makes
    /// this fail.
    func testSignOutConfirmed_alreadyDurablySignedOut_doesNotAskTheWindow() throws {
        var askedCount = 0
        let settings = makeSettingsWindowsController {
            askedCount += 1
            return true
        }
        settings.controller.requestSignOut(account: account, focusedWindowHasSheet: false)
        account.durablySignedOut = true

        try XCTUnwrap(settings.prompter.onSignOut)()

        XCTAssertEqual(askedCount, 0)
        XCTAssertFalse(settings.controller.isSigningOut)
    }

    /// The Mac's Settings window asks about an account held while signed out. Its
    /// confirmation is a sheet on that window only, so the user can sign in on the mailbox
    /// window with it still up, and its Sign Out button then signed that new session out.
    ///
    /// Revert-check: removing the `guard SettingsAppSignOutPolicy.answerStillApplies` from
    /// `SettingsAppSignOutController.signOutConfirmed` makes this fail.
    func testSignOutConfirmed_signedInAfterTheQuestion_signsNothingOutAndSaysSo() throws {
        account.isAuthenticated = false
        account.userEmail = nil
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)
        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertNil(prompter.lastAccountEmail)

        account.isAuthenticated = true
        account.userEmail = "new@example.com"
        try XCTUnwrap(prompter.onSignOut)()

        XCTAssertFalse(controller.isSigningOut)
        XCTAssertFalse(controller.isAnySignOutRunning)
        XCTAssertEqual(prompter.failureCount, 1, "the answer must not look ignored")

        // Refused, not stuck: asked again, the confirmation names the account signed in
        // now, and its answer signs that one out.
        XCTAssertEqual(controller.requestSignOut(account: account, focusedWindowHasSheet: false), .confirm)
        XCTAssertEqual(prompter.lastAccountEmail, "new@example.com")
        try XCTUnwrap(prompter.onSignOut)()
        XCTAssertTrue(controller.isSigningOut)
    }

    /// The session is compared as it was when the question was asked, not as it is when the
    /// handler is made or run.
    ///
    /// Revert-check: taking `asked` inside the `onSignOut` closure, in
    /// `SettingsAppSignOutController.presentConfirmation`, makes this fail: it would be the
    /// session at the answer, and always equal to itself.
    func testSignOutConfirmed_anotherAccountSignedInSinceTheQuestion_signsNothingOut() throws {
        account.userEmail = "old@example.com"
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)
        XCTAssertEqual(prompter.lastAccountEmail, "old@example.com")

        account.userEmail = "new@example.com"
        try XCTUnwrap(prompter.onSignOut)()

        XCTAssertFalse(controller.isSigningOut)
        XCTAssertEqual(prompter.failureCount, 1)
    }

    /// A stale answer is the controller's to refuse. The window is asked, and beeps, only
    /// when there was a sign-out to refuse.
    ///
    /// Revert-check: moving the `guard !refusesConfirmedSignOut()` above the
    /// `answerStillApplies` guard in `SettingsAppSignOutController.signOutConfirmed` makes
    /// this fail.
    func testSignOutConfirmed_staleAnswer_doesNotAskTheWindow() throws {
        var askedCount = 0
        let settings = makeSettingsWindowsController {
            askedCount += 1
            return true
        }
        account.userEmail = "old@example.com"
        settings.controller.requestSignOut(account: account, focusedWindowHasSheet: false)

        account.userEmail = "new@example.com"
        try XCTUnwrap(settings.prompter.onSignOut)()

        XCTAssertEqual(askedCount, 0)
        XCTAssertEqual(settings.prompter.failureCount, 1)
    }

    /// The iOS switch's confirmation can be raised over the sign-in view, for an account
    /// held while signed out, and answered there: nothing changed, so it signs that account
    /// out as before.
    ///
    /// Revert-check: refusing whenever `asked.isAuthenticated` is false, in
    /// `SettingsAppSignOutPolicy.answerStillApplies`, makes this fail.
    func testSignOutConfirmed_heldAccountStillHeld_signsOut() async throws {
        requestSignOut()
        account.isAuthenticated = false
        account.userEmail = nil
        controller.evaluate(account: account, isSceneActive: true)

        try XCTUnwrap(prompter.onSignOut)()

        await waitUntil { self.account.signOutCallCount == 1 }
        XCTAssertEqual(prompter.failureCount, 0)
    }

    // MARK: - A confirmation whose session changed while it was up

    /// The iOS switch was turned on for an account held while signed out (a launch restore
    /// that failed retryably), and the confirmation was left up. A background task then ran
    /// the restore again and signed that account back in. The answer was refused, although
    /// the account was the one the user had asked to sign out, and nothing asked again.
    ///
    /// Revert-check: removing `withdrawStaleConfirmation(account: account)` from
    /// `SettingsAppSignOutController.evaluate` makes this fail: the old confirmation stays
    /// up, and its answer signs nothing out.
    func testEvaluate_heldAccountRestoredUnderTheConfirmation_asksAgainAndThatAnswerSignsOut() async throws {
        requestSignOut()
        account.isAuthenticated = false
        account.userEmail = nil
        controller.evaluate(account: account, isSceneActive: true)
        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertNil(prompter.lastAccountEmail)
        prompter.isConfirmationActive = true

        account.isAuthenticated = true
        account.userEmail = "user@example.com"
        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.withdrawCount, 1)
        XCTAssertEqual(prompter.confirmationCount, 2)
        XCTAssertEqual(prompter.lastAccountEmail, "user@example.com")
        XCTAssertTrue(preferences.isSignOutRequested, "taking the confirmation down answers nothing")

        try XCTUnwrap(prompter.onSignOut)()

        await waitUntil { self.account.signOutCallCount == 1 }
        XCTAssertEqual(prompter.failureCount, 0)
    }

    /// The session can change while the app is in the background, which is where a
    /// background task runs. The confirmation is taken down then, and the request waits, as
    /// any request does, for the scene to be active.
    ///
    /// Revert-check: calling `withdrawStaleConfirmation` only when `isSceneActive`, in
    /// `SettingsAppSignOutController.evaluate`, makes this fail.
    func testEvaluate_staleConfirmationWhileSceneInactive_takesItDownAndAsksWhenActive() {
        requestSignOut()
        account.isAuthenticated = false
        account.userEmail = nil
        controller.evaluate(account: account, isSceneActive: true)
        prompter.isConfirmationActive = true

        account.isAuthenticated = true
        account.userEmail = "user@example.com"
        controller.evaluate(account: account, isSceneActive: false)

        XCTAssertEqual(prompter.withdrawCount, 1)
        XCTAssertEqual(prompter.confirmationCount, 1)

        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.confirmationCount, 2)
        XCTAssertEqual(prompter.lastAccountEmail, "user@example.com")
    }

    /// A prompter leaves a confirmation it cannot take down yet (the UIKit alert while it is
    /// still coming up). The controller asks again at its next look, and only then asks the
    /// user again.
    ///
    /// Revert-check: clearing `confirmationSubject` in
    /// `SettingsAppSignOutController.withdrawStaleConfirmation` makes this fail: the next
    /// look no longer knows the confirmation is about another session.
    func testEvaluate_staleConfirmationNotYetOnScreen_isTakenDownAtTheNextLook() {
        requestSignOut()
        account.isAuthenticated = false
        account.userEmail = nil
        controller.evaluate(account: account, isSceneActive: true)
        prompter.isConfirmationActive = true
        prompter.leavesConfirmationUpWhenWithdrawn = true

        account.isAuthenticated = true
        account.userEmail = "user@example.com"
        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.withdrawCount, 1)
        XCTAssertEqual(prompter.confirmationCount, 1, "nothing is asked over a confirmation still up")

        prompter.leavesConfirmationUpWhenWithdrawn = false
        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.withdrawCount, 2)
        XCTAssertEqual(prompter.confirmationCount, 2)
        XCTAssertEqual(prompter.lastAccountEmail, "user@example.com")
    }

    /// The Mac's Settings window asked about an account held while signed out, and the user
    /// then signed in on the mailbox window. The confirmation stayed up with its old
    /// question, and a Sign Out… chosen on the mailbox window brought it to the front, where
    /// its answer could only be refused.
    ///
    /// Revert-check: removing `withdrawStaleConfirmation(account: account)` from
    /// `SettingsAppSignOutController.refreshHeldAccount` makes this fail.
    func testRefreshHeldAccount_signedInUnderTheConfirmation_takesItDownAndAsksNothing() {
        account.isAuthenticated = false
        account.userEmail = nil
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)
        XCTAssertEqual(prompter.confirmationCount, 1)
        prompter.isConfirmationActive = true

        account.isAuthenticated = true
        account.userEmail = "new@example.com"
        controller.refreshHeldAccount(account: account)

        XCTAssertEqual(prompter.withdrawCount, 1)
        XCTAssertEqual(prompter.confirmationCount, 1, "the Mac stores no request, so nothing asks again")
        XCTAssertEqual(account.signOutCallCount, 0)

        // Chosen again, Sign Out… asks about the account that is signed in now.
        XCTAssertEqual(controller.requestSignOut(account: account, focusedWindowHasSheet: false), .confirm)
        XCTAssertEqual(prompter.lastAccountEmail, "new@example.com")
    }

    /// The ordinary case: the controller is told about the session often (every focus
    /// change on the Mac's mailbox window), and the session is the one that was asked about.
    ///
    /// Revert-check: dropping the `answerStillApplies` guard from
    /// `SettingsAppSignOutController.withdrawStaleConfirmation` makes this fail: every look
    /// would take the confirmation down, and on iOS raise it again.
    func testEvaluateAndRefresh_sessionUnchangedUnderTheConfirmation_leaveItUp() {
        requestSignOut()
        controller.evaluate(account: account, isSceneActive: true)
        XCTAssertEqual(prompter.confirmationCount, 1)
        prompter.isConfirmationActive = true

        controller.evaluate(account: account, isSceneActive: true)
        controller.refreshHeldAccount(account: account)

        XCTAssertEqual(prompter.withdrawCount, 0)
        XCTAssertEqual(prompter.confirmationCount, 1)
    }

    /// The kept session means something only while its confirmation is up. An alert can
    /// leave the screen with neither handler run, and a later sign-in must not be logged,
    /// or acted on, as a confirmation taken down.
    ///
    /// Revert-check: dropping `prompter.isConfirmationActive` from the guard in
    /// `SettingsAppSignOutController.withdrawStaleConfirmation` makes this fail.
    func testRefreshHeldAccount_confirmationAlreadyGone_withdrawsNothing() {
        account.isAuthenticated = false
        account.userEmail = nil
        controller.requestSignOut(account: account, focusedWindowHasSheet: false)
        XCTAssertEqual(prompter.confirmationCount, 1)
        XCTAssertFalse(prompter.isConfirmationActive)

        account.isAuthenticated = true
        account.userEmail = "new@example.com"
        controller.refreshHeldAccount(account: account)
        controller.evaluate(account: account, isSceneActive: true)

        XCTAssertEqual(prompter.withdrawCount, 0)
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

    /// A controller that asks its window again when the user answers Sign Out, as the Mac's
    /// Settings window's does.
    private func makeSettingsWindowsController(
        refusesConfirmedSignOut: @escaping @MainActor () -> Bool
    ) -> (controller: SettingsAppSignOutController, prompter: FakePrompter) {
        let settingsPrompter = FakePrompter()
        let settings = SettingsAppSignOutController(
            preferences: preferences,
            prompter: settingsPrompter,
            activity: activity,
            refusesConfirmedSignOut: refusesConfirmedSignOut
        )
        return (settings, settingsPrompter)
    }

    /// A second window's controller, sharing this test's activity.
    private func makeOtherWindowsController(
        showsFailuresOfOffScreenWindows: Bool = false
    ) -> (controller: SettingsAppSignOutController, prompter: FakePrompter) {
        let otherPrompter = FakePrompter()
        let other = SettingsAppSignOutController(
            preferences: preferences,
            prompter: otherPrompter,
            activity: activity,
            showsFailuresOfOffScreenWindows: showsFailuresOfOffScreenWindows
        )
        return (other, otherPrompter)
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
    private(set) var withdrawCount = 0
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

    /// True for a confirmation that is not on screen to take down yet: the call leaves it.
    var leavesConfirmationUpWhenWithdrawn = false

    func withdrawConfirmation() {
        withdrawCount += 1
        guard !leavesConfirmationUpWhenWithdrawn else { return }
        isConfirmationActive = false
    }

    func presentFailure() {
        failureCount += 1
    }
}
