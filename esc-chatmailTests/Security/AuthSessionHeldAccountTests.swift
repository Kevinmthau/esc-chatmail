import GoogleSignIn
import XCTest
@testable import esc_chatmail

/// A launch restore that cannot reach Google holds the account (`AuthSession.heldAccount`)
/// instead of leaving the first-run sign-in screen over an intact mailbox, and a real
/// revocation still signs out (architecture review 2026-11, fix-order item 5).
///
/// A restore that publishes needs a `GIDGoogleUser`, which earlier suites took to be
/// impossible to make in a test; `StubGoogleUser` makes one, and the one test that
/// publishes (`testRestore_mailboxUncheckableThenCheckable_holdsThenPublishes`) runs that
/// publishing ends the hold (`publishAuthenticatedSession`). The early return for a
/// session an interactive sign-in published is run too.
@MainActor
final class AuthSessionHeldAccountTests: XCTestCase {
    private let storedEmail = "stored@example.com"

    // Revert-check: fails if `concludeLaunchRestoreHold` stops holding the account, or if
    // the restore callback's non-invalidating branch stops holding a connectivity error.
    func testRestore_offline_holdsAccountWithStoredEmailAndKeepsCredentials() async {
        let keychain = makeKeychain()
        let tokenManager = MockTokenManager()
        let recoveries = HeldAccountTestBox(0)
        let session = makeSession(
            keychain: keychain,
            tokenManager: tokenManager,
            restore: { completion in completion(nil, URLError(.notConnectedToInternet)) },
            pendingActionAuthenticationDidRecover: { recoveries.value += 1 }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(session.heldAccount, HeldAccount(email: storedEmail, failure: .cannotConnect))
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertFalse(session.canAccessMailbox)
        XCTAssertNil(session.userEmail, "A held account publishes no session")
        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(session.isDurablySignedOut())
        XCTAssertEqual(recoveries.value, 0, "Pending actions recover only when a session is published")
    }

    /// AppAuth wraps the transport's error, and a timeout from `GoogleAuthTransport`'s
    /// deadline arrives the same way.
    func testRestore_appAuthNetworkErrorWrappingATimeout_holdsAsCannotConnect() async {
        let error = NSError(
            domain: "org.openid.appauth.general",
            code: -5,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]
        )
        let session = makeSession(restore: { completion in completion(nil, error) })

        _ = await session.restorePreviousSignIn()

        XCTAssertEqual(session.heldAccount?.failure, .cannotConnect)
    }

    /// An error asking again cannot mend (`invalid_client`, a bad ID token, a keychain
    /// write) keeps the credentials, as before, but is neither held nor retried: the held
    /// screen would promise a reconnect that never comes.
    // Revert-check: fails if the restore callback holds every non-invalidating error
    // instead of only `isConnectivityRestoreError` ones.
    func testRestore_errorThatIsNeitherConnectivityNorRevocation_keepsCredentialsWithoutHolding() async {
        for error in [
            NSError(domain: kGIDSignInErrorDomain, code: -2),
            NSError(domain: "org.openid.appauth.oauth_token", code: -9),
            NSError(domain: "org.openid.appauth.general", code: -15)
        ] {
            let tokenManager = MockTokenManager()
            let session = makeSession(
                tokenManager: tokenManager,
                restore: { completion in completion(nil, error) }
            )

            let outcome = await session.restorePreviousSignIn()

            XCTAssertEqual(outcome, .retryableFailure, "\(error)")
            XCTAssertNil(session.heldAccount, "\(error)")
            XCTAssertEqual(tokenManager.clearTokensCallCount, 0, "\(error)")
        }
    }

    // Revert-check: fails if the `.indeterminate` branch of `restorePreviousSignIn` stops
    // setting `heldFailure` (GoogleSignIn's item may be there, so it is not a sign-out),
    // or stops asking for a stored address first (a fresh install whose keychain query
    // failed would be told its mail is on the device).
    func testRestore_unreadableGoogleSignInKeychain_holdsOnlyAnAccountTheAppKeychainNames() async {
        let session = makeSession(
            hasPreviousGoogleSignIn: false,
            keychainPresence: .indeterminate,
            restore: { _ in XCTFail("An unreadable SDK item is not restored") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(session.heldAccount?.failure, .couldNotRestore)

        let freshInstall = makeSession(
            keychain: MockKeychainService(),
            hasPreviousGoogleSignIn: false,
            keychainPresence: .indeterminate,
            restore: { _ in XCTFail("An unreadable SDK item is not restored") }
        )

        let freshInstallOutcome = await freshInstall.restorePreviousSignIn()
        XCTAssertEqual(freshInstallOutcome, .retryableFailure)
        XCTAssertNil(freshInstall.heldAccount)
    }

    // Revert-check: fails if a restore that cannot read the local-cleanup marker (the first
    // keychain read, in `resumeInterruptedAccountRemovalIfNeeded`) drops the hold: every
    // retry would then stop and the first-run sign-in screen show over intact credentials
    // until the next launch.
    // HONEST SCOPE: the same keep in the credential-cleanup and durable signed-out reads
    // (`keepsExistingHold`, `keepingHoldIfUnreadable`) is never reached here: the mock's
    // one-shot error is spent on the first read.
    func testRetryAfterHold_unreadableMarker_keepsTheHold() async {
        let keychain = makeKeychain()
        let sdkRestores = HeldAccountTestBox(0)
        let session = makeSession(keychain: keychain, restore: { completion in
            sdkRestores.value += 1
            completion(nil, URLError(.notConnectedToInternet))
        })
        _ = await session.restorePreviousSignIn()
        XCTAssertNotNil(session.heldAccount)

        keychain.errorToThrow = KeychainError.unhandledError(status: errSecInteractionNotAllowed)
        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(sdkRestores.value, 1, "The marker read failed before the SDK restore")
        XCTAssertEqual(session.heldAccount, HeldAccount(email: storedEmail, failure: .cannotConnect))
    }

    // A restore whose account preparation could not check the mailbox and changed nothing
    // (the reset marker unreadable) keeps the credentials and holds the account
    // (`AuthRestorePreparationPolicy`); the next attempt that can check it publishes the
    // session with those credentials and ends the hold (architecture review 2026-11,
    // `account-boundary-auth#4`).
    // Revert-check: fails if the restore callback's preparation catch clears the session
    // for a nothing-changed stage (the second restore then finds the signed-out verdict
    // and ends terminal), or stops holding the account for it.
    func testRestore_mailboxUncheckableThenCheckable_holdsThenPublishes() async {
        let keychain = makeKeychain()
        let tokenManager = MockTokenManager()
        let sdkRestores = HeldAccountTestBox(0)
        let recoveries = HeldAccountTestBox(0)
        let email = storedEmail
        let session = makeSession(
            keychain: keychain,
            tokenManager: tokenManager,
            restore: { completion in
                sdkRestores.value += 1
                if sdkRestores.value == 1 {
                    // The launch's own read of the marker has passed; the preparation's fails.
                    keychain.failNextLoad(
                        for: KeychainService.Key.localStoreResetRequired.rawValue,
                        with: KeychainError.unhandledError(status: errSecInteractionNotAllowed)
                    )
                }
                completion(StubGoogleUser(email: email), nil)
            },
            pendingActionAuthenticationDidRecover: { recoveries.value += 1 }
        )

        let firstOutcome = await session.restorePreviousSignIn()

        XCTAssertEqual(firstOutcome, .retryableFailure)
        XCTAssertEqual(session.heldAccount, HeldAccount(email: storedEmail, failure: .couldNotRestore))
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertEqual(recoveries.value, 0)

        let secondOutcome = await session.restorePreviousSignIn()

        XCTAssertEqual(secondOutcome, .authenticated)
        XCTAssertEqual(sdkRestores.value, 2)
        XCTAssertNil(session.heldAccount, "Publishing ends the hold")
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertEqual(session.userEmail, storedEmail)
        XCTAssertEqual(tokenManager.lastSavedAccessToken, "stub-access-token")
        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertEqual(recoveries.value, 1, "Only a published session recovers pending actions")
    }

    // invalid_grant on a retry signs out exactly as it does at launch, and ends the hold.
    // Revert-check: fails only if both `clearAuthState()` stops clearing `heldAccount` and
    // `concludeLaunchRestoreHold` stops clearing it for an ending with no hold; either
    // one alone ends it, by design.
    func testRetryAfterHold_invalidGrant_signsOutAndEndsHold() async {
        let keychain = makeKeychain()
        let tokenManager = MockTokenManager()
        let nextError = HeldAccountTestBox<Error>(URLError(.networkConnectionLost))
        let googleSignOuts = HeldAccountTestBox(0)
        let session = makeSession(
            keychain: keychain,
            tokenManager: tokenManager,
            restore: { completion in completion(nil, nextError.value) },
            signOutGoogleSession: { googleSignOuts.value += 1 }
        )
        _ = await session.restorePreviousSignIn()
        XCTAssertNotNil(session.heldAccount)

        nextError.value = NSError(domain: "org.openid.appauth.oauth_token", code: -10)
        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertNil(session.heldAccount)
        XCTAssertEqual(googleSignOuts.value, 1)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertTrue(session.isDurablySignedOut())
    }

    /// The retry joins the launch's own single-flight restore, which runs the SDK restore
    /// again after a retryable outcome; the hold stays on screen while it runs.
    func testBootstrapRestoreRunAgainAfterHold_restoresAgainAndKeepsHoldWhileStillOffline() async {
        let sdkRestores = HeldAccountTestBox(0)
        let holdSeenDuringSecondRestore = HeldAccountTestBox<HeldAccount?>(nil)
        let sessionBox = HeldAccountTestBox<AuthSession?>(nil)
        let session = makeSession(restore: { completion in
            sdkRestores.value += 1
            if sdkRestores.value == 2 {
                holdSeenDuringSecondRestore.value = sessionBox.value?.heldAccount
            }
            completion(nil, URLError(.cannotFindHost))
        })
        sessionBox.value = session
        defer { sessionBox.value = nil }
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: { true },
            restoreAuthenticationOperation: { await session.restorePreviousSignIn() }
        )

        _ = await bootstrap.restoreAuthenticationIfNeeded()
        _ = await bootstrap.restoreAuthenticationIfNeeded()

        XCTAssertEqual(sdkRestores.value, 2)
        XCTAssertEqual(holdSeenDuringSecondRestore.value?.failure, .cannotConnect)
        XCTAssertEqual(session.heldAccount?.failure, .cannotConnect)
    }

    // Revert-check: fails if `registerAccountRemovalRequest` stops clearing `heldAccount`.
    // Neither sign-out path calls `clearAuthState()`, so nothing else ends the hold, and
    // the held screen stayed over a wiped mailbox with its retries running.
    func testSignOutPaths_endHold() async {
        for disconnects in [false, true] {
            let session = makeSession(restore: { completion in completion(nil, URLError(.timedOut)) })
            _ = await session.restorePreviousSignIn()
            XCTAssertNotNil(session.heldAccount)

            if disconnects {
                // No user means no token to revoke: it throws after its local cleanup.
                try? await session.signOutAndDisconnect()
            } else {
                _ = await session.signOut()
            }

            XCTAssertNil(session.heldAccount, disconnects ? "signOutAndDisconnect" : "signOut")
        }
    }

    // Revert-check: fails if `concludeLaunchRestoreHold` stops checking
    // `isAccountRemovalRequested`. A sign-out asked for while the restore waited on
    // Google cleared the hold at its registration; the restore ending after it then held
    // the account again, and the sign-out, which never calls `clearAuthState()`, left it.
    func testRestoreEndingAfterSignOutWasAsked_doesNotHold() async {
        let pendingCompletion = HeldAccountTestBox<((GIDGoogleUser?, Error?) -> Void)?>(nil)
        let session = makeSession(restore: { completion in pendingCompletion.value = completion })

        let restore = Task { await session.restorePreviousSignIn() }
        await waitUntil { pendingCompletion.value != nil }
        let signOut = Task { await session.signOut() }
        // `signOut()` registers its request before its first suspension.
        await waitUntil { session.isDurablySignedOut() }
        pendingCompletion.value?(nil, URLError(.notConnectedToInternet))

        let outcome = await restore.value
        _ = await signOut.value

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertNil(session.heldAccount)
    }

    /// A retry that finds a session an interactive sign-in published (Sign In Again on
    /// the held screen) ends without holding anything.
    func testRestoreAfterInteractiveSignInPublished_endsHold() async {
        let session = makeSession(restore: { completion in completion(nil, URLError(.timedOut)) })
        _ = await session.restorePreviousSignIn()
        XCTAssertNotNil(session.heldAccount)
        session.isAuthenticated = true

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .authenticated)
        XCTAssertNil(session.heldAccount)
    }

    // MARK: - Error classification

    func testConnectivityRestoreErrorClassification() {
        let connectivity: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            URLError(.secureConnectionFailed),
            NSError(domain: "org.openid.appauth.general", code: -5),
            NSError(domain: "org.openid.appauth.general", code: -6),
            NSError(domain: "org.openid.appauth.oauth_token", code: -7),
            NSError(domain: "org.openid.appauth.oauth_token", code: -8),
            NSError(
                domain: "com.google.GTMSessionFetcher",
                code: -1,
                userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
            )
        ]
        for error in connectivity {
            XCTAssertTrue(AuthSession.isConnectivityRestoreError(error), "\(error)")
            XCTAssertFalse(AuthSession.isCredentialInvalidatingRestoreError(error), "\(error)")
        }

        let other: [Error] = [
            NSError(domain: kGIDSignInErrorDomain, code: -2),
            NSError(domain: "org.openid.appauth.general", code: -7),
            NSError(domain: "org.openid.appauth.oauth_token", code: -9),
            NSError(domain: "AuthSessionHeldAccountTests", code: 1)
        ]
        for error in other {
            XCTAssertFalse(AuthSession.isConnectivityRestoreError(error), "\(error)")
        }
    }

    // MARK: - Fixtures

    private func makeKeychain() -> MockKeychainService {
        let keychain = MockKeychainService()
        keychain.preloadStrings([KeychainService.Key.googleUserEmail.rawValue: storedEmail])
        return keychain
    }

    private func makeSession(
        keychain: MockKeychainService? = nil,
        tokenManager: MockTokenManager = MockTokenManager(),
        hasPreviousGoogleSignIn: Bool = true,
        keychainPresence: GoogleSignInKeychainPresence = .present,
        restore: @escaping @MainActor @Sendable (@escaping (GIDGoogleUser?, Error?) -> Void) -> Void,
        signOutGoogleSession: @escaping @MainActor @Sendable () -> Void = {},
        pendingActionAuthenticationDidRecover: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> AuthSession {
        AuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain ?? makeKeychain(),
            hasPreviousGoogleSignIn: { hasPreviousGoogleSignIn },
            googleSignInKeychainPresence: { keychainPresence },
            restorePreviousGoogleSignIn: restore,
            interactiveGoogleSignIn: { _, _, _ in },
            signOutGoogleSession: signOutGoogleSession,
            userDefaults: UserDefaults(suiteName: "AuthSessionHeldAccountTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            clearParticipantCaches: {},
            reopenParticipantCaches: {},
            cleanupDownloads: {},
            reopenDownloads: { true },
            resetPendingActionRetryState: {},
            pendingActionAuthenticationDidRecover: pendingActionAuthenticationDidRecover,
            resetSyncStorageState: {},
            cancelBackgroundTaskRequests: {},
            resetCoreDataStore: {},
            inspectLocalMailboxStore: {
                LocalMailboxStoreInspection(
                    accountEmails: [],
                    hasAccountScopedRows: false,
                    hasAccountScopedFiles: false
                )
            },
            deleteAttachmentFiles: {},
            clearAttachmentCache: {},
            cleanupHTMLContent: {},
            reopenHTMLContent: {},
            syncRunCoordinator: SyncRunCoordinator(),
            outboundTaskRegistry: OutboundTaskRegistry(),
            revokeGoogleToken: { _ in }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

/// A mutable value the tests' `@Sendable` stubs write. Every stub runs on the main actor.
private final class HeldAccountTestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
