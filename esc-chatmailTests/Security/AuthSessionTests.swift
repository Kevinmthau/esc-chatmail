import GoogleSignIn
import XCTest
@testable import esc_chatmail

@MainActor
final class AuthSessionTests: XCTestCase {
    // Revert-check: fails if AuthSession.requireReauthentication() stops setting
    // `requiresReauthentication` (or reverts to tearing the session down), or if
    // `canAccessMailbox` stops subtracting that flag from `isAuthenticated`. A
    // revoked refresh token must park the mailbox, not sign the account out and
    // take its isolated local store and durable pending actions with it.
    func testRequireReauthenticationPreservesAuthenticatedMailboxState() {
        let session = makeAuthSession()
        session.isAuthenticated = true
        session.userEmail = "person@example.com"
        session.accessToken = "expired-access-token"

        session.requireReauthentication()

        XCTAssertTrue(session.isAuthenticated)
        XCTAssertTrue(session.requiresReauthentication)
        XCTAssertFalse(session.canAccessMailbox)
        XCTAssertEqual(session.userEmail, "person@example.com")
        XCTAssertEqual(session.accessToken, "expired-access-token")
    }

    // Revert-check: the `requiresReauthentication` assertion fails if
    // requireReauthentication()'s `guard isAuthenticated else { return }` is
    // removed. A refresh failure that lands before any session is published
    // would otherwise latch a reauthentication demand onto a signed-out app,
    // where no sign-in flow can clear it except publishAuthenticatedSession.
    func testRequireReauthenticationDoesNothingWithoutAuthenticatedSession() {
        let session = makeAuthSession()

        session.requireReauthentication()

        XCTAssertFalse(session.requiresReauthentication)
        XCTAssertFalse(session.canAccessMailbox)
    }

    // Revert-check: fails if `await resetPendingActionRetryState()` is removed
    // from AuthSession.signOut() (firstIndex(of:) goes nil) or moved after
    // completeDurableLocalCleanupForAccountRemoval(). PendingActionsManager is
    // process-wide, so the old account's retry timers and credential-recovery
    // latch must be retired before the store reset, not inherited by the next.
    func testSignOutResetsPendingActionRetryStateBeforeStoreCleanup() async {
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            resetPendingActionRetryState: {
                cleanup.record("pending-retries-reset")
            },
            resetCoreDataStore: {
                cleanup.record("store-reset")
            }
        )
        session.isAuthenticated = true

        let didSignOut = await session.signOut()

        XCTAssertTrue(didSignOut)
        let retryResetIndex = cleanup.events.firstIndex(of: "pending-retries-reset")
        let storeResetIndex = cleanup.events.firstIndex(of: "store-reset")
        XCTAssertNotNil(retryResetIndex)
        XCTAssertNotNil(storeResetIndex)
        if let retryResetIndex, let storeResetIndex {
            XCTAssertLessThan(retryResetIndex, storeResetIndex)
        }
    }

    func testWithFreshToken_reusesSingleInjectedTokenManagerInstance() async throws {
        let factory = AuthSessionTokenManagerFactory()
        let session = makeAuthSession(tokenManagerProvider: { factory.makeDistinctTokenManager() })

        let firstToken = try await session.withFreshToken()
        let secondToken = try await session.withFreshToken()

        XCTAssertEqual(firstToken, "token-1")
        XCTAssertEqual(secondToken, "token-1")
        XCTAssertEqual(factory.createdManagers.count, 1)
        XCTAssertEqual(factory.createdManagers.first?.getCurrentTokenCallCount, 2)
    }

    func testNormalizedLoginHint_trimsWhitespace() {
        XCTAssertEqual(
            AuthSession.normalizedLoginHint("  person@example.com \n"),
            "person@example.com"
        )
    }

    func testNormalizedLoginHint_returnsNilForEmptyInput() {
        XCTAssertNil(AuthSession.normalizedLoginHint(nil))
        XCTAssertNil(AuthSession.normalizedLoginHint(""))
        XCTAssertNil(AuthSession.normalizedLoginHint("   \n\t"))
    }

    func testGoogleTokenRevocationRequestFormEncodesOpaqueToken() throws {
        let request = AuthSession.googleTokenRevocationRequest(for: "a+b&c=d%e /")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(String(data: body, encoding: .utf8), "token=a%2Bb%26c%3Dd%25e%20%2F")
    }

    func testCurrentOrPersistedUserEmail_prefersInMemoryValue() {
        let keychain = MockKeychainService()
        keychain.preloadStrings([KeychainService.Key.googleUserEmail.rawValue: "stored@example.com"])
        let session = makeAuthSession(keychainService: keychain)
        session.userEmail = "memory@example.com"

        XCTAssertEqual(session.currentOrPersistedUserEmail(), "memory@example.com")
    }

    func testCurrentOrPersistedUserEmail_fallsBackToPersistedValue() {
        let keychain = MockKeychainService()
        keychain.preloadStrings([KeychainService.Key.googleUserEmail.rawValue: "stored@example.com"])
        let session = makeAuthSession(keychainService: keychain)

        XCTAssertEqual(session.currentOrPersistedUserEmail(), "stored@example.com")
    }

    func testCurrentOrPersistedUserEmail_returnsNilWhenPersistedValueMissing() {
        let session = makeAuthSession(keychainService: MockKeychainService())

        XCTAssertNil(session.currentOrPersistedUserEmail())
    }

    func testPersistUserEmailForBackgroundAccess_usesBackgroundReadableAccess() throws {
        let keychain = MockKeychainService()
        let session = makeAuthSession(keychainService: keychain)

        try session.persistUserEmailForBackgroundAccess("stored@example.com")

        XCTAssertEqual(
            keychain.accessLevel(for: KeychainService.Key.googleUserEmail.rawValue),
            .afterFirstUnlockThisDeviceOnly
        )
        XCTAssertEqual(
            try keychain.loadString(for: KeychainService.Key.googleUserEmail.rawValue),
            "stored@example.com"
        )
    }

    func testPersistSessionForBackgroundAccess_migratesLegacyTokensToBackgroundReadableAccess() throws {
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        var defaultsMarkerWasClearedBeforeKeychainDelete = false
        keychain.onDelete = { key in
            guard key == KeychainService.Key.credentialCleanupRequired.rawValue else { return }
            defaultsMarkerWasClearedBeforeKeychainDelete = !defaults.bool(
                forKey: AuthSession.credentialCleanupRequiredKey
            )
        }
        let tokenManagerProvider = TokenManagerProvider()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManagerProvider.tokenManager },
            keychainService: keychain,
            userDefaults: defaults
        )
        tokenManagerProvider.tokenManager = TokenManager(
            keychainService: keychain,
            authSession: session,
            tokenRefresher: MockTokenRefresher()
        )

        let legacyExpiration = Date().addingTimeInterval(300)
        try keychain.saveCodable(
            TokenInfo(
                accessToken: "legacy-access",
                refreshToken: "legacy-refresh",
                expirationDate: legacyExpiration,
                scope: GoogleConfig.scopes.joined(separator: " ")
            ),
            for: KeychainService.Key.googleAccessToken.rawValue,
            withAccess: .whenUnlockedThisDeviceOnly
        )
        try keychain.saveString(
            "legacy-refresh",
            for: KeychainService.Key.googleRefreshToken.rawValue,
            withAccess: .whenUnlockedThisDeviceOnly
        )

        let migratedExpiration = Date().addingTimeInterval(3600)
        try session.persistSessionForBackgroundAccess(
            accessToken: "restored-access",
            refreshToken: "restored-refresh",
            expirationDate: migratedExpiration,
            email: "stored@example.com"
        )

        let storedToken = try keychain.loadCodable(
            TokenInfo.self,
            for: KeychainService.Key.googleAccessToken.rawValue
        )
        XCTAssertEqual(storedToken.accessToken, "restored-access")
        XCTAssertEqual(storedToken.refreshToken, "restored-refresh")
        XCTAssertEqual(
            storedToken.expirationDate.timeIntervalSince1970,
            migratedExpiration.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            keychain.accessLevel(for: KeychainService.Key.googleAccessToken.rawValue),
            .afterFirstUnlockThisDeviceOnly
        )
        XCTAssertEqual(
            try keychain.loadString(for: KeychainService.Key.googleRefreshToken.rawValue),
            "restored-refresh"
        )
        XCTAssertEqual(
            keychain.accessLevel(for: KeychainService.Key.googleRefreshToken.rawValue),
            .afterFirstUnlockThisDeviceOnly
        )
        XCTAssertEqual(
            try keychain.loadString(for: KeychainService.Key.googleUserEmail.rawValue),
            "stored@example.com"
        )
        XCTAssertEqual(
            keychain.accessLevel(for: KeychainService.Key.googleUserEmail.rawValue),
            .afterFirstUnlockThisDeviceOnly
        )
        XCTAssertTrue(defaultsMarkerWasClearedBeforeKeychainDelete)
        XCTAssertFalse(defaults.bool(forKey: AuthSession.credentialCleanupRequiredKey))
    }

    func testCredentialPersistenceFailureLeavesMarkerAndLaunchCleanupDeletesPartialTokens() async throws {
        struct EmailPersistenceFailure: Error {}
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        let tokenManagerProvider = TokenManagerProvider()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManagerProvider.tokenManager },
            keychainService: keychain,
            userDefaults: defaults,
            clearParticipantCaches: { cleanup.markParticipantCachesCleared() },
            cleanupDownloads: { cleanup.markDownloadsCleared() },
            resetCoreDataStore: { cleanup.markStoreReset() },
            deleteAttachmentFiles: { cleanup.markAttachmentFilesCleared() }
        )
        tokenManagerProvider.tokenManager = TokenManager(
            keychainService: keychain,
            authSession: session,
            tokenRefresher: MockTokenRefresher()
        )
        keychain.failNextSave(
            for: KeychainService.Key.googleUserEmail.rawValue,
            with: EmailPersistenceFailure()
        )

        XCTAssertThrowsError(
            try session.persistSessionForBackgroundAccess(
                accessToken: "partially-saved-access",
                refreshToken: "partially-saved-refresh",
                expirationDate: Date().addingTimeInterval(3600),
                email: "partial@example.com"
            )
        )
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleAccessToken.rawValue))
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleRefreshToken.rawValue))
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue))
        XCTAssertTrue(defaults.bool(forKey: AuthSession.credentialCleanupRequiredKey))

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleAccessToken.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleRefreshToken.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue))
        XCTAssertFalse(defaults.bool(forKey: AuthSession.credentialCleanupRequiredKey))
        XCTAssertTrue(cleanup.participantCachesCleared)
        XCTAssertTrue(cleanup.downloadsCleared)
        XCTAssertFalse(cleanup.storeReset, "Credential recovery must preserve an already-isolated local store")
        XCTAssertFalse(cleanup.attachmentFilesCleared)
    }

    func testRestoreTransientErrorPreservesGoogleAndPersistedCredentials() async {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "stored@example.com"
        ])
        let tokenManager = MockTokenManager()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            hasPreviousGoogleSignIn: { true },
            restorePreviousGoogleSignIn: { completion in
                completion(nil, URLError(.notConnectedToInternet))
            },
            signOutGoogleSession: { cleanup.record("google-sign-out") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue))
        XCTAssertFalse(cleanup.events.contains("google-sign-out"))
    }

    func testRestoreTransientAppAuthTokenErrorsPreserveGoogleAndPersistedCredentials() async {
        for errorCode in [-7, -8] {
            let keychain = MockKeychainService()
            keychain.preloadStrings([
                KeychainService.Key.googleUserEmail.rawValue: "stored@example.com"
            ])
            let tokenManager = MockTokenManager()
            let cleanup = AuthSessionCleanupRecorder()
            let session = makeAuthSession(
                tokenManagerProvider: { tokenManager },
                keychainService: keychain,
                hasPreviousGoogleSignIn: { true },
                restorePreviousGoogleSignIn: { completion in
                    completion(
                        nil,
                        NSError(domain: "org.openid.appauth.oauth_token", code: errorCode)
                    )
                },
                signOutGoogleSession: { cleanup.record("google-sign-out") }
            )

            let outcome = await session.restorePreviousSignIn()

            XCTAssertEqual(outcome, .retryableFailure, "AppAuth error code: \(errorCode)")
            XCTAssertEqual(tokenManager.clearTokensCallCount, 0, "AppAuth error code: \(errorCode)")
            XCTAssertTrue(
                keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue),
                "AppAuth error code: \(errorCode)"
            )
            XCTAssertFalse(
                keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue),
                "AppAuth error code: \(errorCode)"
            )
            XCTAssertFalse(
                cleanup.events.contains("google-sign-out"),
                "AppAuth error code: \(errorCode)"
            )
        }
    }

    func testInteractiveSignInCancellationBeforeResultPreservesPersistedCredentials() async {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "stored@example.com"
        ])
        let tokenManager = MockTokenManager()
        tokenManager.currentToken = "persisted-token"
        let cleanup = AuthSessionCleanupRecorder()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: false)
        let cancellation = NSError(domain: kGIDSignInErrorDomain, code: -5)
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            interactiveGoogleSignIn: { _, _, completion in
                completion(nil, cancellation)
            },
            signOutGoogleSession: { cleanup.record("google-sign-out") },
            cleanupDownloads: { cleanup.record("downloads-closed") },
            reopenDownloads: {
                cleanup.record("downloads-reopened")
                return true
            },
            outboundTaskRegistry: outboundTaskRegistry
        )

        do {
            try await session.signIn(presenting: UIViewController())
            XCTFail("Expected interactive sign-in cancellation")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, kGIDSignInErrorDomain)
            XCTAssertEqual(error.code, -5)
        }

        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertEqual(tokenManager.currentToken, "persisted-token")
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue))
        XCTAssertFalse(cleanup.events.contains("google-sign-out"))
        XCTAssertEqual(cleanup.events, ["downloads-closed"])
        XCTAssertNil(
            outboundTaskRegistry.reserve(),
            "A canceled sign-in must not admit account work while the session remains signed out"
        )
    }

    func testAuthenticatedInteractiveSignInCancellationReopensParticipantCaches() async {
        let cleanup = AuthSessionCleanupRecorder()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let cancellation = NSError(domain: kGIDSignInErrorDomain, code: -5)
        let session = makeAuthSession(
            interactiveGoogleSignIn: { _, _, completion in
                completion(nil, cancellation)
            },
            clearParticipantCaches: { cleanup.record("participants-closed") },
            reopenParticipantCaches: { cleanup.record("participants-reopened") },
            cleanupDownloads: { cleanup.record("downloads-closed") },
            reopenDownloads: {
                cleanup.record("downloads-reopened")
                return true
            },
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        do {
            try await session.signIn(presenting: UIViewController())
            XCTFail("Expected interactive sign-in cancellation")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, kGIDSignInErrorDomain)
            XCTAssertEqual(error.code, -5)
        }

        XCTAssertEqual(
            cleanup.events,
            [
                "participants-closed",
                "downloads-closed",
                "participants-reopened",
                "downloads-reopened"
            ]
        )
        let reservation = outboundTaskRegistry.reserve()
        XCTAssertNotNil(
            reservation,
            "Canceling account replacement must restore the authenticated account's admission"
        )
        if let reservation {
            outboundTaskRegistry.finish(reservation)
        }
    }

    // Revert-check: fails if reopenPreSignInAccountWork(after:)'s refused-downloads
    // leg returns early (the all-or-none shape reopenAccountWork(after:) uses)
    // instead of logging and continuing. That caller cannot unpublish the
    // session it is restoring, so bailing before
    // outboundTaskRegistry.reopenAdmission(after:) would leave a live,
    // authenticated account permanently unable to send — a strictly wider blast
    // radius than the attachment latch it is reacting to.
    func testRefusedDownloadReopenStillRestoresOutboundAdmissionForPublishedSession() async {
        let cleanup = AuthSessionCleanupRecorder()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let cancellation = NSError(domain: kGIDSignInErrorDomain, code: -5)
        let session = makeAuthSession(
            interactiveGoogleSignIn: { _, _, completion in
                completion(nil, cancellation)
            },
            clearParticipantCaches: { cleanup.record("participants-closed") },
            reopenParticipantCaches: { cleanup.record("participants-reopened") },
            cleanupDownloads: { cleanup.record("downloads-closed") },
            reopenDownloads: {
                cleanup.record("downloads-reopen-refused")
                return false
            },
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        do {
            try await session.signIn(presenting: UIViewController())
            XCTFail("Expected interactive sign-in cancellation")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, kGIDSignInErrorDomain)
            XCTAssertEqual(error.code, -5)
        }

        XCTAssertEqual(
            cleanup.events,
            [
                "participants-closed",
                "downloads-closed",
                "participants-reopened",
                "downloads-reopen-refused"
            ],
            "A degraded attachment reopen must not trigger the all-or-none rollback"
        )
        XCTAssertTrue(session.isAuthenticated)
        let reservation = outboundTaskRegistry.reserve()
        XCTAssertNotNil(
            reservation,
            "A still-published session must keep sending even when attachment admission stays latched"
        )
        if let reservation {
            outboundTaskRegistry.finish(reservation)
        }
    }

    func testRetryableStartupRestoreThenInteractiveSignInSkipsLaterBootstrapRestore() async {
        let cleanup = AuthSessionCleanupRecorder()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let session = makeAuthSession(
            hasPreviousGoogleSignIn: { true },
            restorePreviousGoogleSignIn: { completion in
                cleanup.record("google-restore")
                completion(nil, URLError(.notConnectedToInternet))
            },
            cleanupDownloads: {
                cleanup.record("downloads-closed")
            },
            outboundTaskRegistry: outboundTaskRegistry
        )
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: { true },
            restoreAuthenticationOperation: {
                await session.restorePreviousSignIn()
            }
        )

        let startupResult = await bootstrap.restoreAuthenticationIfNeeded()

        XCTAssertTrue(startupResult)
        XCTAssertEqual(cleanup.events.filter { $0 == "google-restore" }.count, 1)
        XCTAssertEqual(cleanup.events.filter { $0 == "downloads-closed" }.count, 1)

        // Model the account boundary established by a successful interactive
        // sign-in after the transient restore left the signed-out UI visible.
        let interactiveTransition = outboundTaskRegistry.closeAdmission()
        XCTAssertTrue(outboundTaskRegistry.reopenAdmission(after: interactiveTransition))
        session.isAuthenticated = true

        let backgroundResult = await bootstrap.prepareForBackgroundSync()

        XCTAssertTrue(backgroundResult)
        XCTAssertEqual(
            cleanup.events.filter { $0 == "google-restore" }.count,
            1,
            "Background startup must not retry the Google restore after interactive sign-in"
        )
        XCTAssertEqual(
            cleanup.events.filter { $0 == "downloads-closed" }.count,
            1,
            "The redundant bootstrap call must not close newly reopened account work"
        )
        XCTAssertNotNil(
            outboundTaskRegistry.reserve(),
            "Interactive sign-in's outbound admission must remain open"
        )
    }

    // Revert-check: fails if `restorePreviousSignIn()` or `signIn(presenting:)` drops
    // its `await beginAuthenticationTransition()` / `defer { endAuthenticationTransition() }`
    // pair. Without the gate the background restore closes participants/downloads
    // concurrently with the cancelled sign-in's rollback, so the recorded order is no
    // longer reopen-then-close and the two transitions interleave their generations.
    func testBootstrapRestoreRetryDoesNotSupersedeInteractiveSignInTransition() async {
        let cleanup = AuthSessionCleanupRecorder()
        let interactiveSignIn = AuthSessionInteractiveSignInGate()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let transientRestoreError = URLError(.notConnectedToInternet)
        let session = makeAuthSession(
            hasPreviousGoogleSignIn: { true },
            restorePreviousGoogleSignIn: { completion in
                cleanup.record("google-restore")
                completion(nil, transientRestoreError)
            },
            interactiveGoogleSignIn: { _, _, completion in
                interactiveSignIn.begin(completion: completion)
            },
            clearParticipantCaches: { cleanup.record("participants-closed") },
            reopenParticipantCaches: { cleanup.record("participants-reopened") },
            cleanupDownloads: { cleanup.record("downloads-closed") },
            reopenDownloads: {
                cleanup.record("downloads-reopened")
                return true
            },
            outboundTaskRegistry: outboundTaskRegistry
        )
        let bootstrap = AppStartupBootstrap(
            preparePersistenceOperation: { true },
            restoreAuthenticationOperation: {
                await session.restorePreviousSignIn()
            }
        )

        let initialRestoreResult = await bootstrap.restoreAuthenticationIfNeeded()
        XCTAssertTrue(initialRestoreResult)

        // Start a replacement transition and hold its Google callback open.
        // Toggling the published state lets the cancellation rollback expose
        // whether a concurrent restore advanced the outbound generation while
        // the interactive transition owned it.
        session.isAuthenticated = true
        let signInTask = Task { @MainActor in
            try await session.signIn(presenting: UIViewController())
        }
        await interactiveSignIn.waitUntilStarted()
        session.isAuthenticated = false
        let eventStart = cleanup.events.count

        let backgroundRestoreTask = Task {
            await bootstrap.prepareForBackgroundSync()
        }
        // Deterministic: the restore has genuinely parked on the auth-transition
        // gate (owned by the interactive sign-in) before the rollback begins.
        await session.waitUntilAuthenticationTransitionWaiterCountForTesting(1)
        interactiveSignIn.cancel()

        do {
            try await signInTask.value
            XCTFail("Expected the injected interactive sign-in cancellation")
        } catch {
            // Expected.
        }
        let backgroundRestoreResult = await backgroundRestoreTask.value
        XCTAssertTrue(backgroundRestoreResult)

        XCTAssertEqual(
            Array(cleanup.events.dropFirst(eventStart)),
            [
                "participants-reopened",
                "downloads-reopened",
                "participants-closed",
                "downloads-closed",
                "google-restore"
            ],
            "The restore retry must wait until interactive rollback has reopened its own generation"
        )
    }

    func testRestoreTerminalGoogleErrorClearsRejectedCredentials() async {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "stored@example.com"
        ])
        let tokenManager = MockTokenManager()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            hasPreviousGoogleSignIn: { true },
            restorePreviousGoogleSignIn: { completion in
                completion(
                    nil,
                    NSError(domain: kGIDSignInErrorDomain, code: -4)
                )
            },
            signOutGoogleSession: { cleanup.record("google-sign-out") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertTrue(cleanup.events.contains("google-sign-out"))
    }

    func testRestoreNilUserWithoutErrorClearsRejectedCredentials() async {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "stored@example.com"
        ])
        let tokenManager = MockTokenManager()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            hasPreviousGoogleSignIn: { true },
            restorePreviousGoogleSignIn: { completion in
                completion(nil, nil)
            },
            signOutGoogleSession: { cleanup.record("google-sign-out") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertTrue(cleanup.events.contains("google-sign-out"))
    }

    func testCredentialInvalidatingRestoreErrorClassificationIsNarrow() {
        XCTAssertTrue(
            AuthSession.isCredentialInvalidatingRestoreError(
                NSError(domain: kGIDSignInErrorDomain, code: -4)
            )
        )
        XCTAssertTrue(
            AuthSession.isCredentialInvalidatingRestoreError(
                NSError(domain: "org.openid.appauth.oauth_token", code: -10)
            )
        )
        XCTAssertFalse(
            AuthSession.isCredentialInvalidatingRestoreError(
                NSError(domain: kGIDSignInErrorDomain, code: -2)
            )
        )
        XCTAssertFalse(
            AuthSession.isCredentialInvalidatingRestoreError(
                URLError(.timedOut)
            )
        )
    }

    func testSignOutMarkerPersistenceFailureKeepsAuthenticatedStateAndReopensAdmission() async throws {
        struct MarkerPersistenceFailure: Error {}
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "still-signed-in@example.com"
        ])
        let tokenManager = MockTokenManager()
        tokenManager.currentToken = "still-valid-token"
        let cleanup = AuthSessionCleanupRecorder()
        let coordinator = SyncRunCoordinator()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            userDefaults: defaults,
            reopenDownloads: {
                cleanup.markDownloadsReopened()
                return true
            },
            resetCoreDataStore: { cleanup.markStoreReset() },
            deleteAttachmentFiles: { cleanup.markAttachmentFilesCleared() },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            syncRunCoordinator: coordinator,
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true
        session.userEmail = "still-signed-in@example.com"
        session.accessToken = "still-valid-token"
        keychain.errorToThrow = MarkerPersistenceFailure()

        let didSignOut = await session.signOut()

        XCTAssertFalse(didSignOut)
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertEqual(session.userEmail, "still-signed-in@example.com")
        XCTAssertEqual(session.accessToken, "still-valid-token")
        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue))
        XCTAssertFalse(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))
        XCTAssertFalse(cleanup.storeReset)
        XCTAssertFalse(cleanup.attachmentFilesCleared)
        XCTAssertFalse(cleanup.downloadsReopened)
        XCTAssertFalse(cleanup.events.contains("html-reopened"))
        let reservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        outboundTaskRegistry.finish(reservation)
    }

    func testDisconnectMarkerPersistenceFailureDoesNotRevokeOrPublishLoggedOutState() async {
        struct MarkerPersistenceFailure: Error {}
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "still-signed-in@example.com"
        ])
        let tokenManager = MockTokenManager()
        tokenManager.currentToken = "still-valid-token"
        let cleanup = AuthSessionCleanupRecorder()
        let coordinator = SyncRunCoordinator()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            userDefaults: defaults,
            reopenDownloads: {
                cleanup.markDownloadsReopened()
                return true
            },
            resetCoreDataStore: { cleanup.markStoreReset() },
            deleteAttachmentFiles: { cleanup.markAttachmentFilesCleared() },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            syncRunCoordinator: coordinator,
            outboundTaskRegistry: outboundTaskRegistry,
            revokeGoogleToken: { _ in cleanup.record("revoke") }
        )
        session.isAuthenticated = true
        session.userEmail = "still-signed-in@example.com"
        session.accessToken = "still-valid-token"
        keychain.errorToThrow = MarkerPersistenceFailure()

        do {
            try await session.signOutAndDisconnect()
            XCTFail("Expected marker persistence to abort disconnect")
        } catch let error as AuthError {
            guard case .cleanupPrerequisitePersistenceFailed = error else {
                return XCTFail("Unexpected auth error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(session.isAuthenticated)
        XCTAssertEqual(session.userEmail, "still-signed-in@example.com")
        XCTAssertEqual(session.accessToken, "still-valid-token")
        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(cleanup.storeReset)
        XCTAssertFalse(cleanup.attachmentFilesCleared)
        XCTAssertFalse(cleanup.events.contains("revoke"))
        XCTAssertFalse(cleanup.downloadsReopened)
        XCTAssertFalse(cleanup.events.contains("html-reopened"))
        let reservation = outboundTaskRegistry.reserve()
        XCTAssertNotNil(reservation)
        if let reservation {
            outboundTaskRegistry.finish(reservation)
        }
    }

    // Revert-check: the two timestamp assertions below fail if
    // AuthSession.clearAccountScopedSyncDefaults() stops removing
    // SyncConfig.lastSuccessfulSyncTimeKey / lastReconciliationTimeKey (i.e. if
    // it reverts to the legacy failure-keys-only clear).
    func testSignOutClearsLegacySyncStateEvenWhenStoreResetFails() async {
        struct StoreResetFailure: Error {}
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        defaults.set(2, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.set(["old-message"], forKey: SyncConfig.persistentFailedIdsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastReconciliationTimeKey)
        let session = makeAuthSession(
            keychainService: keychain,
            userDefaults: defaults,
            resetCoreDataStore: { throw StoreResetFailure() }
        )

        await session.signOut()

        XCTAssertNil(defaults.object(forKey: SyncConfig.consecutiveFailuresKey))
        XCTAssertNil(defaults.object(forKey: SyncConfig.persistentFailedIdsKey))
        XCTAssertNil(
            defaults.object(forKey: SyncConfig.lastSuccessfulSyncTimeKey),
            "A destroyed store must not bequeath a we-synced-recently signal, even when the reset itself failed"
        )
        XCTAssertNil(
            defaults.object(forKey: SyncConfig.lastReconciliationTimeKey),
            "A destroyed store must not bequeath a we-reconciled-recently signal, even when the reset itself failed"
        )
        XCTAssertTrue(
            defaults.bool(forKey: AuthSession.localStoreResetRequiredKey),
            "A failed destructive reset must remain a durable prerequisite for the next login"
        )
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        )
        XCTAssertEqual(
            keychain.accessLevel(for: KeychainService.Key.localStoreResetRequired.rawValue),
            .afterFirstUnlockThisDeviceOnly
        )
    }

    func testSignOutClearsParticipantCachesEvenWhenStoreResetFails() async {
        struct StoreResetFailure: Error {}
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            clearParticipantCaches: { cleanup.markParticipantCachesCleared() },
            resetCoreDataStore: { throw StoreResetFailure() }
        )

        await session.signOut()

        XCTAssertTrue(
            cleanup.participantCachesCleared,
            "An account transition must evict cached Person names and profile-photo results even when durable cleanup will retry"
        )
    }

    // Revert-check: fails if `signOut()` drops its `cancelBackgroundTaskRequests()`
    // step. Without it the pending com.esc.inboxchat.refresh/.processing requests
    // survive sign-out, and each fire re-arms itself at handler entry before the
    // unauthenticated guard runs, so a signed-out device takes discretionary
    // background wakes indefinitely.
    func testSignOutCancelsPendingBackgroundTaskRequestsEvenWhenStoreResetFails() async {
        struct StoreResetFailure: Error {}
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            cancelBackgroundTaskRequests: { cleanup.record("bg-task-requests-cancelled") },
            resetCoreDataStore: { throw StoreResetFailure() }
        )

        await session.signOut()

        XCTAssertEqual(
            cleanup.events,
            ["bg-task-requests-cancelled"],
            "Sign-out must disarm pending background sync task requests even when durable cleanup will retry"
        )
    }

    // Revert-check: fails if `signOutAndDisconnect()` drops its
    // `cancelBackgroundTaskRequests()` step.
    func testSignOutAndDisconnectCancelsPendingBackgroundTaskRequestsEvenWhenRevocationFails() async {
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            cancelBackgroundTaskRequests: { cleanup.record("bg-task-requests-cancelled") }
        )

        // With no authenticated user there is no revocation token, so the
        // disconnect throws after its local cleanup; the disarm must already
        // have happened by then.
        do {
            try await session.signOutAndDisconnect()
            XCTFail("Disconnect without a revocation token should rethrow the revocation failure")
        } catch {}

        XCTAssertEqual(
            cleanup.events,
            ["bg-task-requests-cancelled"],
            "Disconnect must disarm pending background sync task requests even when remote revocation fails"
        )
    }

    // Revert-check: fails if `resumeInterruptedAccountRemovalIfNeeded()` drops its
    // `cancelBackgroundTaskRequests()` step — a sign-out interrupted by a crash
    // must still disarm the sync task requests when its durable marker is resumed
    // at the next launch.
    func testRestoreResumedAccountRemovalCancelsPendingBackgroundTaskRequests() async throws {
        let keychain = MockKeychainService()
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.localStoreResetRequired.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            keychainService: keychain,
            cancelBackgroundTaskRequests: { cleanup.record("bg-task-requests-cancelled") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(cleanup.events, ["bg-task-requests-cancelled"])
    }

    // Revert-check: fails if `resumeInterruptedCredentialCleanupIfNeeded()` drops
    // its `cancelBackgroundTaskRequests()` step — a launch that concludes signed
    // out by finishing an interrupted credential transaction must not leave the
    // sync task requests armed.
    func testRestoreResumedCredentialCleanupCancelsPendingBackgroundTaskRequests() async throws {
        let keychain = MockKeychainService()
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.credentialCleanupRequired.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            keychainService: keychain,
            cancelBackgroundTaskRequests: { cleanup.record("bg-task-requests-cancelled") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(cleanup.events, ["bg-task-requests-cancelled"])
    }

    // Revert-check: fails if `clearFailedGoogleSession()` drops its
    // `cancelBackgroundTaskRequests()` step. A restore rejected with an
    // invalidated credential concludes signed out with tokens cleared, so every
    // surviving BGTask fire would be the same perpetual no-op wake sign-out
    // disarms.
    func testRestoreTerminalGoogleErrorCancelsPendingBackgroundTaskRequests() async {
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            hasPreviousGoogleSignIn: { true },
            restorePreviousGoogleSignIn: { completion in
                completion(
                    nil,
                    NSError(domain: kGIDSignInErrorDomain, code: -4)
                )
            },
            cancelBackgroundTaskRequests: { cleanup.record("bg-task-requests-cancelled") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(cleanup.events, ["bg-task-requests-cancelled"])
    }

    // HONEST SCOPE: this pins the deliberate seam — BGTask disarming belongs to
    // the transitions that conclude signed out, not to the store-repair cleanup
    // sign-in and restore run while concluding authenticated (where the scene
    // handler owns re-arming). It cannot detect removal of the sign-out
    // cancellation itself; the positive tests above own that.
    func testAccountPreparationStoreResetDoesNotCancelPendingBackgroundTaskRequests() async throws {
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            cancelBackgroundTaskRequests: { cleanup.record("bg-task-requests-cancelled") },
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertTrue(
            cleanup.events.isEmpty,
            "Repairing a stale store on the way into an authenticated session must not disarm background sync"
        )
    }

    func testCleanupPrerequisiteSurvivesFreshSessionWhenDefaultsStateIsLost() async throws {
        let keychain = MockKeychainService()
        let resetScript = AuthSessionStoreResetScript(failuresBeforeSuccess: 1)
        let firstSession = makeAuthSession(
            keychainService: keychain,
            userDefaults: makeDefaults(),
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        await firstSession.signOut()

        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        )

        // A new defaults suite models losing any unflushed in-process
        // UserDefaults state during a crash. The fresh AuthSession must still
        // observe the Keychain prerequisite before allowing authentication.
        let freshSession = makeAuthSession(
            keychainService: keychain,
            userDefaults: makeDefaults(),
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] }
        )
        try await freshSession.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertEqual(resetScript.attemptCount, 2)
        XCTAssertFalse(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        )
    }

    func testRestorePreviousSignInResumesMarkedCleanupWithoutGoogleSession() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasCompletedSignIn")
        defaults.set(2, forKey: SyncConfig.consecutiveFailuresKey)
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "old@example.com"
        ])
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.localStoreResetRequired.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        let tokenManager = MockTokenManager()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            userDefaults: defaults,
            clearConversationCaches: { cleanup.markConversationCachesCleared() },
            clearParticipantCaches: { cleanup.markParticipantCachesCleared() },
            cleanupDownloads: { cleanup.markDownloadsCleared() },
            resetCoreDataStore: { cleanup.markStoreReset() },
            deleteAttachmentFiles: { cleanup.markAttachmentFilesCleared() },
            clearAttachmentCache: { cleanup.markAttachmentCacheCleared() }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        )
        XCTAssertNil(defaults.object(forKey: "hasCompletedSignIn"))
        XCTAssertNil(defaults.object(forKey: SyncConfig.consecutiveFailuresKey))
        XCTAssertTrue(cleanup.storeReset)
        XCTAssertTrue(cleanup.conversationCachesCleared)
        XCTAssertTrue(cleanup.participantCachesCleared)
        XCTAssertTrue(cleanup.downloadsCleared)
        XCTAssertTrue(cleanup.attachmentFilesCleared)
        XCTAssertTrue(cleanup.attachmentCacheCleared)
    }

    func testRestorePreviousSignInReportsRetryableFailureWhenMarkedCleanupFails() async throws {
        let keychain = MockKeychainService()
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.localStoreResetRequired.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        let resetScript = AuthSessionStoreResetScript(failuresBeforeSuccess: 1)
        let session = makeAuthSession(
            keychainService: keychain,
            resetCoreDataStore: { try resetScript.reset() }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Failed durable cleanup must remain eligible for a later restore retry"
        )
    }

    // Revert-check: fails if `hasPersistedCleanupRequirement(key:defaultsKey:)` goes
    // back to the non-throwing `keychainService.exists(...)` property that
    // `resumeInterruptedAccountRemovalIfNeeded` consumed. `exists` swallows the
    // OSStatus into `false`, so restore would decide no cleanup is pending and reach
    // `hasPreviousGoogleSignIn` — the recorded events are then non-empty.
    func testRestoreDefersWhenCleanupMarkerReadIsIndeterminate() async {
        struct MarkerReadFailure: Error {}
        let keychain = MockKeychainService()
        keychain.errorToThrow = MarkerReadFailure()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            keychainService: keychain,
            hasPreviousGoogleSignIn: {
                cleanup.record("google-session-checked")
                return true
            },
            restorePreviousGoogleSignIn: { _ in
                cleanup.record("google-restore")
            },
            resetCoreDataStore: {
                cleanup.markStoreReset()
            }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertTrue(cleanup.events.isEmpty)
        XCTAssertFalse(cleanup.storeReset)
    }

    func testCredentialCleanupFailureRetainsMarkerUntilFreshRetrySucceeds() async throws {
        struct CredentialCleanupFailure: Error {}
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "old@example.com"
        ])
        let tokenManager = MockTokenManager()
        tokenManager.clearError = CredentialCleanupFailure()
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] }
        )

        await session.signOut()

        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Credential cleanup failure must retain the durable retry prerequisite"
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertEqual(tokenManager.clearTokensCallCount, 2)
        XCTAssertEqual(resetScript.attemptCount, 2)
        XCTAssertFalse(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        )
    }

    func testAccountPreparationRetriesFailedSignOutResetBeforeAllowingAuthentication() async throws {
        let defaults = makeDefaults()
        let resetScript = AuthSessionStoreResetScript(failuresBeforeSuccess: 1)
        let session = makeAuthSession(
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        await session.signOut()
        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertTrue(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertEqual(resetScript.attemptCount, 2)
        XCTAssertFalse(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))
    }

    // Revert-check: fails if `prepareLocalStoreForAuthenticatedAccount(_:)` stops
    // wrapping `try hasPersistedLocalCleanupRequirement()` in the do/catch that maps
    // a read failure to `AuthError.localAccountIsolationFailed`. With the old
    // `exists()`-backed property the failure reads as "no marker", the empty account
    // list inspects clean, and preparation returns without throwing — publishing an
    // account over a store whose pending reset could not be proven absent.
    func testAccountPreparationFailsClosedWhenCleanupMarkerReadIsIndeterminate() async {
        struct MarkerReadFailure: Error {}
        let keychain = MockKeychainService()
        keychain.errorToThrow = MarkerReadFailure()
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            keychainService: keychain,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] }
        )

        do {
            try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")
            XCTFail("An indeterminate marker read must block account publication")
        } catch let error as AuthError {
            guard case .localAccountIsolationFailed = error else {
                return XCTFail("Unexpected auth error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(resetScript.attemptCount, 0)
    }

    func testAccountPreparationClearsParticipantCachesBeforeReopeningMismatchedStore() async throws {
        let resetScript = AuthSessionStoreResetScript()
        let cleanup = AuthSessionCleanupRecorder()
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let transition = registry.closeAdmission()
        let session = makeAuthSession(
            clearParticipantCaches: {
                cleanup.markParticipantCachesCleared()
                cleanup.record("participant-caches-cleared")
            },
            reopenDownloads: {
                cleanup.record("downloads-reopened")
                return true
            },
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["first@example.com"] },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            outboundTaskRegistry: registry
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("SECOND@example.com")
        let reopenOutcome = await session.reopenAccountWork(after: transition)

        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertEqual(reopenOutcome, .reopened)
        XCTAssertTrue(
            cleanup.participantCachesCleared,
            "Direct account replacement must evict the previous store's cached participant identity before account work reopens"
        )
        XCTAssertEqual(
            cleanup.events,
            ["participant-caches-cleared", "html-reopened", "downloads-reopened"]
        )
    }

    func testAccountPreparationKeepsAccountlessTrulyEmptyStore() async throws {
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] },
            hasStoredAccountScopedMailboxData: { false }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("first@example.com")

        XCTAssertEqual(resetScript.attemptCount, 0)
    }

    // Revert-check: fails if any entry is dropped from
    // `AccountScopedMailboxFileInspector.hasStoredFiles(appSupportDirectory:cachesDirectory:)`'s
    // `directories` list — Attachments, Previews, AttachmentCache,
    // EmailPreviewSnapshots. The literals here deliberately duplicate
    // `AttachmentPaths`/`EmailPreviewSnapshotCache.directoryName` so renaming a
    // constant without updating the cleanup path is caught too.
    func testAccountScopedMailboxFileInspectorDetectsEveryCleanupDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AuthSessionFileInspection-\(UUID().uuidString)", isDirectory: true)
        let appSupportDirectory = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let cachesDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: cachesDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertFalse(
            AccountScopedMailboxFileInspector.hasStoredFiles(
                appSupportDirectory: appSupportDirectory,
                cachesDirectory: cachesDirectory,
                fileManager: fileManager
            )
        )

        let directories = [
            appSupportDirectory.appendingPathComponent("Attachments", isDirectory: true),
            appSupportDirectory.appendingPathComponent("Previews", isDirectory: true),
            cachesDirectory.appendingPathComponent("AttachmentCache", isDirectory: true),
            cachesDirectory.appendingPathComponent("EmailPreviewSnapshots", isDirectory: true)
        ]
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("orphan"))
            XCTAssertTrue(
                AccountScopedMailboxFileInspector.hasStoredFiles(
                    appSupportDirectory: appSupportDirectory,
                    cachesDirectory: cachesDirectory,
                    fileManager: fileManager
                ),
                "\(directory.lastPathComponent) must make an accountless store require cleanup"
            )
            try fileManager.removeItem(at: directory)
        }
    }

    // Revert-check: fails if `AccountScopedMailboxFileInspector.hasStoredFiles`'s
    // trailing `catch { return true }` becomes a `continue`/`return false`, or if the
    // narrow `.fileReadNoSuchFile`/`.fileNoSuchFile` catch is widened to swallow every
    // error. An unreadable directory would then read as empty and let
    // `prepareLocalStoreForAuthenticatedAccount` skip cleanup of another account's files.
    func testAccountScopedMailboxFileInspectorFailsClosedOnEnumerationError() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AuthSessionFileInspection-\(UUID().uuidString)", isDirectory: true)
        let appSupportDirectory = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let cachesDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: cachesDirectory,
            withIntermediateDirectories: true
        )
        // A regular file where a directory is expected forces enumeration to
        // fail. The inspector must not collapse that error into "empty."
        try Data([1]).write(to: appSupportDirectory.appendingPathComponent("Attachments"))

        XCTAssertTrue(
            AccountScopedMailboxFileInspector.hasStoredFiles(
                appSupportDirectory: appSupportDirectory,
                cachesDirectory: cachesDirectory,
                fileManager: fileManager
            )
        )
    }

    func testAccountPreparationReplacesAccountlessStoreWithOrphanedMailboxData() async throws {
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] },
            hasStoredAccountScopedMailboxData: { true }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertEqual(
            resetScript.attemptCount,
            1,
            "Mailbox rows without an Account owner must be treated as foreign data"
        )
    }

    func testAccountPreparationReplacesAccountlessStoreWithLegacyCanonicalHTML() async throws {
        let resetScript = AuthSessionStoreResetScript()
        let htmlCleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] },
            // Production folds surviving canonical HTML into this inspection.
            hasStoredAccountScopedMailboxData: { true },
            cleanupHTMLContent: { htmlCleanup.record("html") }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertEqual(
            htmlCleanup.events,
            ["html"],
            "Legacy canonical HTML must be deleted before account work reopens"
        )
    }

    // Revert-check: the two timestamp assertions fail if
    // AuthSession.clearAccountScopedSyncDefaults() stops removing
    // SyncConfig.lastSuccessfulSyncTimeKey / lastReconciliationTimeKey. The
    // replaced store has never synced for this account, so SyncTimeCalculator
    // and shouldSkipLabelReconciliation must not read the previous account's
    // watermarks.
    func testAccountPreparationClearsInheritedSyncTimestampsWhenReplacingMismatchedStore() async throws {
        let defaults = makeDefaults()
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastReconciliationTimeKey)
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["first@example.com"] }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("second@example.com")

        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertNil(
            defaults.object(forKey: SyncConfig.lastSuccessfulSyncTimeKey),
            "Replacing a foreign account's store must not leave its we-synced-recently watermark behind"
        )
        XCTAssertNil(
            defaults.object(forKey: SyncConfig.lastReconciliationTimeKey),
            "Replacing a foreign account's store must not let the new account skip label reconciliation"
        )
    }

    func testAccountPreparationKeepsMatchingStoreWithoutReset() async throws {
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["Person@Example.com"] }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")

        XCTAssertEqual(resetScript.attemptCount, 0)
    }

    func testAccountPreparationReplacesStoreWhenMatchingAndForeignAccountRowsCoexist() async throws {
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: {
                // The matching row intentionally comes first: fetching one
                // arbitrary Account must never be accepted as store ownership.
                ["second@example.com", "first@example.com"]
            }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("second@example.com")

        XCTAssertEqual(resetScript.attemptCount, 1)
    }

    func testAccountPreparationFailsClosedWhenMismatchedStoreCannotReset() async {
        let defaults = makeDefaults()
        let resetScript = AuthSessionStoreResetScript(failuresBeforeSuccess: 1)
        let session = makeAuthSession(
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["first@example.com"] }
        )

        do {
            try await session.prepareLocalStoreForAuthenticatedAccount("second@example.com")
            XCTFail("Expected account isolation to reject the sign-in transition")
        } catch is AuthError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(session.isAuthenticated)
        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertTrue(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))
    }

    // Revert-check: two independent orderings. The timestamp/continuation assertions
    // fail if `clearAccountScopedSyncDefaults()` + `BackgroundSyncStateManager
    // .clearContinuationState(in:)` move back to the tail of
    // `prepareLocalStoreForAuthenticatedAccount(_:)`, where a throwing marker delete
    // skips them. `defaultsMarkerWasClearedBeforeKeychainDelete` and the surviving
    // Keychain marker fail if `clearPersistedCleanupRequirement(key:defaultsKey:)`
    // reverts to delete-then-removeObject or stops restoring the defaults mirror when
    // the authoritative delete throws.
    func testAccountPreparationClearsSyncStateBeforeDeletingDurableResetMarker() async throws {
        struct MarkerDeletionFailure: Error {}
        let defaults = makeDefaults()
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastReconciliationTimeKey)
        let backgroundState = BackgroundSyncStateManager(defaults: defaults)
        try backgroundState.storeContinuationState(
            .history(
                startHistoryId: "old-history",
                pageToken: "old-page",
                accountEmail: "old@example.com"
            )
        )
        let keychain = MockKeychainService()
        var defaultsMarkerWasClearedBeforeKeychainDelete = false
        keychain.onDelete = { key in
            guard key == KeychainService.Key.localStoreResetRequired.rawValue else { return }
            defaultsMarkerWasClearedBeforeKeychainDelete = !defaults.bool(
                forKey: AuthSession.localStoreResetRequiredKey
            )
        }
        keychain.failNextDelete(
            for: KeychainService.Key.localStoreResetRequired.rawValue,
            with: MarkerDeletionFailure()
        )
        let session = makeAuthSession(
            keychainService: keychain,
            userDefaults: defaults,
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        do {
            try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")
            XCTFail("Expected reset-marker deletion to fail account isolation")
        } catch let error as AuthError {
            guard case .localAccountIsolationFailed = error else {
                return XCTFail("Unexpected auth error: \(error)")
            }
        }

        XCTAssertNil(defaults.object(forKey: SyncConfig.lastSuccessfulSyncTimeKey))
        XCTAssertNil(defaults.object(forKey: SyncConfig.lastReconciliationTimeKey))
        XCTAssertNil(backgroundState.getContinuationState())
        XCTAssertTrue(
            defaultsMarkerWasClearedBeforeKeychainDelete,
            "The defaults mirror must be flushed away while Keychain still protects crash recovery"
        )
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "The marker must survive until every account-scoped default is durably cleared"
        )
        XCTAssertTrue(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))
    }

    // Revert-check: the two timestamp assertions fail if
    // AuthSession.clearAccountScopedSyncDefaults() stops removing
    // SyncConfig.lastSuccessfulSyncTimeKey / lastReconciliationTimeKey. A failed
    // remote revocation must still leave the local account-scoped defaults clear
    // completed.
    func testDisconnectFailureStillCompletesLocalAccountCleanup() async {
        struct DisconnectFailure: Error {}
        let defaults = makeDefaults()
        defaults.set(2, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.set(["old-message"], forKey: SyncConfig.persistentFailedIdsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastReconciliationTimeKey)
        defaults.set(true, forKey: "hasCompletedSignIn")
        let tokenManager = MockTokenManager()
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "old@example.com"
        ])
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            userDefaults: defaults,
            clearConversationCaches: { cleanup.markConversationCachesCleared() },
            clearParticipantCaches: { cleanup.markParticipantCachesCleared() },
            cleanupDownloads: { cleanup.markDownloadsCleared() },
            resetCoreDataStore: { cleanup.markStoreReset() },
            deleteAttachmentFiles: { cleanup.markAttachmentFilesCleared() },
            clearAttachmentCache: { cleanup.markAttachmentCacheCleared() },
            revokeGoogleToken: { _ in throw DisconnectFailure() }
        )
        session.accessToken = "old-access-token"

        do {
            try await session.signOutAndDisconnect()
            XCTFail("Expected the injected disconnect failure")
        } catch is DisconnectFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(defaults.object(forKey: SyncConfig.consecutiveFailuresKey))
        XCTAssertNil(defaults.object(forKey: SyncConfig.persistentFailedIdsKey))
        XCTAssertNil(
            defaults.object(forKey: SyncConfig.lastSuccessfulSyncTimeKey),
            "A failed remote revocation must still have completed the local account-scoped defaults clear"
        )
        XCTAssertNil(
            defaults.object(forKey: SyncConfig.lastReconciliationTimeKey),
            "A failed remote revocation must still have completed the local account-scoped defaults clear"
        )
        XCTAssertNil(defaults.object(forKey: "hasCompletedSignIn"))
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertTrue(cleanup.storeReset)
        XCTAssertTrue(cleanup.conversationCachesCleared)
        XCTAssertTrue(cleanup.participantCachesCleared)
        XCTAssertTrue(cleanup.downloadsCleared)
        XCTAssertTrue(cleanup.attachmentFilesCleared)
        XCTAssertTrue(cleanup.attachmentCacheCleared)
    }

    func testAttachmentFileCleanupFailureRemainsDurableAndRetriesBeforeAuthentication() async throws {
        let defaults = makeDefaults()
        let fileCleanup = AuthSessionFileCleanupScript(failuresBeforeSuccess: 1)
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] },
            deleteAttachmentFiles: { try fileCleanup.deleteFiles() }
        )

        await session.signOut()

        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertEqual(fileCleanup.attemptCount, 1)
        XCTAssertTrue(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertEqual(resetScript.attemptCount, 2)
        XCTAssertEqual(fileCleanup.attemptCount, 2)
        XCTAssertFalse(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))
    }

    func testHTMLCleanupFailureRemainsDurableAndRetriesBeforeAuthentication() async throws {
        let defaults = makeDefaults()
        let htmlCleanup = AuthSessionHTMLCleanupScript(failuresBeforeSuccess: 1)
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] },
            cleanupHTMLContent: { try htmlCleanup.cleanup() }
        )

        await session.signOut()

        XCTAssertEqual(htmlCleanup.attemptCount, 1)
        XCTAssertTrue(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        XCTAssertEqual(htmlCleanup.attemptCount, 2)
        XCTAssertFalse(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))
    }

    func testDelayedTokenRevocationStartsAfterLocalCleanupAndHoldsLeaseUntilBoundedRequestCompletes() async throws {
        let coordinator = SyncRunCoordinator()
        let cleanup = AuthSessionCleanupRecorder()
        let disconnect = AuthSessionTokenRevocationGate(recorder: cleanup)
        let session = makeAuthSession(
            tokenManagerProvider: {
                RecordingTokenManager(onClear: { cleanup.record("tokens") })
            },
            resetCoreDataStore: {
                cleanup.record("store")
                cleanup.markStoreReset()
            },
            deleteAttachmentFiles: {
                cleanup.record("files")
                cleanup.markAttachmentFilesCleared()
            },
            clearAttachmentCache: {
                cleanup.record("cache")
                cleanup.markAttachmentCacheCleared()
            },
            syncRunCoordinator: coordinator,
            revokeGoogleToken: { token in
                try await disconnect.revoke(token)
            }
        )
        session.accessToken = "captured-old-access-token"

        let disconnectTask = Task { @MainActor in
            try await session.signOutAndDisconnect()
        }
        await disconnect.waitUntilStarted()
        while !cleanup.attachmentCacheCleared {
            await Task.yield()
        }

        XCTAssertTrue(cleanup.storeReset)
        XCTAssertTrue(cleanup.attachmentFilesCleared)
        let revokedToken = await disconnect.revokedToken
        XCTAssertEqual(revokedToken, "captured-old-access-token")
        XCTAssertEqual(cleanup.events.last, "disconnect")
        let blockedRun = await coordinator.beginRun(kind: .foregroundInitial)
        XCTAssertNil(
            blockedRun,
            "The bounded token revocation finishes before the account-transition lease is released"
        )

        await disconnect.release()
        try await disconnectTask.value

        let nextRun = await coordinator.beginRun(kind: .foregroundInitial)
        XCTAssertNotNil(nextRun)
        if let nextRun {
            await coordinator.endRun(nextRun)
        }
    }

    func testSuccessfulAccountIsolationReopensAttachmentAdmissionBeforePublication() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let transition = registry.closeAdmission()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            reopenDownloads: {
                cleanup.markDownloadsReopened()
                return true
            },
            fetchStoredAccountEmails: { [] },
            outboundTaskRegistry: registry
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        let reopenOutcome = await session.reopenAccountWork(after: transition)
        XCTAssertEqual(reopenOutcome, .reopened)
        XCTAssertTrue(cleanup.downloadsReopened)
        let reservation = registry.reserve()
        XCTAssertNotNil(reservation)
        if let reservation {
            registry.finish(reservation)
        }
    }

    func testFailedHTMLReopenRollsBackPartialAdmissionBeforeQuiescenceCanEnd() async {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let transition = registry.closeAdmission()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            cleanupHTMLContent: {
                cleanup.record("html-rollback")
            },
            reopenHTMLContent: {
                cleanup.record("html-partially-reopened")
                throw NSError(domain: "AuthSessionTests", code: 1)
            },
            outboundTaskRegistry: registry
        )

        let reopenOutcome = await session.reopenAccountWork(after: transition)

        XCTAssertEqual(
            reopenOutcome,
            .transientFailure,
            "A thrown reopen step is retryable; classifying it as latched would discard reusable credentials"
        )
        XCTAssertEqual(
            cleanup.events,
            ["html-partially-reopened", "html-rollback"]
        )
        XCTAssertNil(
            registry.reserve(),
            "Outbound work must remain closed when HTML admission cannot be reopened atomically"
        )
    }

    // Revert-check: fails if AuthSession.discardRestoredSessionAfterFailedReopen()
    // stops routing through clearFailedGoogleSession() — the Google sign-out,
    // the token clear, and the persisted-email delete all go unrecorded, and the
    // outcome stops being .terminalNoSession. A restore persists live
    // background-readable credentials before the reopen sequence runs, so a
    // refused reopen that returns without clearing them strands an account
    // nothing ever cleans up.
    //
    // HONEST SCOPE: this drives the decision method directly instead of through
    // restorePreviousSignIn(). Reaching the reopen-disposition switch requires a
    // restored GIDGoogleUser, which cannot be constructed in tests. The trigger
    // block itself is therefore UNPINNED: deleting the whole `switch
    // AuthRestoreReopenPolicy.restoreDispositionAfterReopen(...)` from
    // restorePreviousSignIn keeps this suite green. What is pinned is the
    // decision (AuthRestoreReopenPolicyTests) and the clearing behavior (here).
    func testDiscardingRestoredSessionAfterFailedReopenClearsStagedCredentials() {
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "restored@example.com"
        ])
        let tokenManager = MockTokenManager()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            signOutGoogleSession: { cleanup.record("google-sign-out") },
            userDefaults: defaults
        )
        session.isAuthenticated = true
        session.userEmail = "restored@example.com"
        session.accessToken = "restored-access-token"

        let outcome = session.discardRestoredSessionAfterFailedReopen()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(cleanup.events, ["google-sign-out"])
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue))
        XCTAssertFalse(defaults.bool(forKey: AuthSession.credentialCleanupRequiredKey))
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertNil(session.userEmail)
        XCTAssertNil(session.accessToken)
    }

    // Revert-check: fails if discardRestoredSessionAfterFailedReopen() stops
    // mapping a failed credential delete to .retryableFailure (for example by
    // hard-coding .terminalNoSession), or if clearFailedGoogleSession() stops
    // persisting the durable marker before its first delete. Without both, a
    // Keychain failure during this discard leaves the restored account's
    // credentials behind with no launch-time retry.
    //
    // HONEST SCOPE: same as above — the restorePreviousSignIn() call site cannot
    // be exercised because GIDGoogleUser is not constructible in tests, so the
    // trigger block that invokes this method is unpinned.
    func testDiscardingRestoredSessionRetainsCleanupMarkerWhenCredentialDeleteFails() {
        struct EmailDeleteFailure: Error {}
        let defaults = makeDefaults()
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "restored@example.com"
        ])
        let tokenManager = MockTokenManager()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            userDefaults: defaults
        )
        keychain.failNextDelete(
            for: KeychainService.Key.googleUserEmail.rawValue,
            with: EmailDeleteFailure()
        )

        let outcome = session.discardRestoredSessionAfterFailedReopen()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue),
            "A failed discard must retain the marker so launch recovery retries the deletes"
        )
        XCTAssertTrue(defaults.bool(forKey: AuthSession.credentialCleanupRequiredKey))
    }

    // Revert-check: fails if AuthSession.reopenAccountWork(after:) stops
    // consuming the Bool returned by reopenDownloads, or stops reporting that
    // refusal as .latchedRefusal. A refused attachment reopen would otherwise
    // publish a session whose downloads and file imports can never be admitted
    // again, with outbound admission wide open.
    //
    // HONEST SCOPE: the refusal is injected. Neither
    // AttachmentAccountWorkRegistry nor AttachmentDownloader can be left with
    // outstanding operations through AuthSession's own transition paths today,
    // because cleanupDownloads() drains both before this runs; this pins the
    // all-or-none contract against a future leak, not a reachable regression.
    func testRefusedDownloadReopenRollsBackEveryReopenedSubsystem() async {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let transition = registry.closeAdmission()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            clearParticipantCaches: { cleanup.record("participants-rollback") },
            reopenParticipantCaches: { cleanup.record("participants-reopened") },
            cleanupDownloads: { cleanup.record("downloads-rollback") },
            reopenDownloads: {
                cleanup.record("downloads-reopen-refused")
                return false
            },
            cleanupHTMLContent: { cleanup.record("html-rollback") },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            outboundTaskRegistry: registry
        )

        let reopenOutcome = await session.reopenAccountWork(after: transition)

        XCTAssertEqual(
            reopenOutcome,
            .latchedRefusal,
            "A refused download reopen is latched, not retryable"
        )
        XCTAssertEqual(
            cleanup.events,
            [
                "html-reopened",
                "participants-reopened",
                "downloads-reopen-refused",
                "downloads-rollback",
                "participants-rollback",
                "html-rollback"
            ]
        )
        XCTAssertNil(
            registry.reserve(),
            "A refused download reopen must leave every account-scoped admission closed"
        )
    }

    // Revert-check: fails if AuthSession.reopenAttachmentAdmission(...) collapses
    // to a short-circuiting `await reopenRegistry() && reopenDownloader()` — the
    // second owner would never be asked to reopen, staying latched closed with
    // no matching rollback and no log naming it.
    //
    // HONEST SCOPE: this pins the helper, not the production `reopenDownloads`
    // default closure that calls it. That closure reaches
    // AttachmentAccountWorkRegistry.shared and AttachmentDownloader.shared, so
    // its wiring (and its AttachmentPaths.setupDirectories() /
    // cache-actor-reopen neighbours) remains uncovered here.
    func testReopenAttachmentAdmissionEvaluatesBothOwnersWhenEitherRefuses() async {
        let refusedRegistry = AuthSessionCleanupRecorder()
        let registryRefusedResult = await AuthSession.reopenAttachmentAdmission(
            reopenRegistry: {
                refusedRegistry.record("registry")
                return false
            },
            reopenDownloader: {
                refusedRegistry.record("downloader")
                return true
            }
        )

        XCTAssertFalse(registryRefusedResult)
        XCTAssertEqual(
            refusedRegistry.events,
            ["registry", "downloader"],
            "A refusing registry must not skip the downloader's reopen"
        )

        let refusedDownloader = AuthSessionCleanupRecorder()
        let downloaderRefusedResult = await AuthSession.reopenAttachmentAdmission(
            reopenRegistry: {
                refusedDownloader.record("registry")
                return true
            },
            reopenDownloader: {
                refusedDownloader.record("downloader")
                return false
            }
        )

        XCTAssertFalse(downloaderRefusedResult)
        XCTAssertEqual(refusedDownloader.events, ["registry", "downloader"])

        let bothReopened = await AuthSession.reopenAttachmentAdmission(
            reopenRegistry: { true },
            reopenDownloader: { true }
        )
        XCTAssertTrue(bothReopened)
    }

    func testSupersededTransitionRollsBackEveryReopenedSubsystem() async {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let staleTransition = registry.closeAdmission()
        _ = registry.closeAdmission()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            clearParticipantCaches: { cleanup.record("participants-rollback") },
            reopenParticipantCaches: { cleanup.record("participants-reopened") },
            cleanupDownloads: { cleanup.record("downloads-rollback") },
            reopenDownloads: {
                cleanup.record("downloads-reopened")
                return true
            },
            cleanupHTMLContent: { cleanup.record("html-rollback") },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            outboundTaskRegistry: registry
        )

        let reopenOutcome = await session.reopenAccountWork(after: staleTransition)

        XCTAssertEqual(
            reopenOutcome,
            .supersededByAccountRemoval,
            "The superseding sign-out owns credential cleanup; this transition must not claim it"
        )
        XCTAssertEqual(
            cleanup.events,
            [
                "html-reopened",
                "participants-reopened",
                "downloads-reopened",
                "downloads-rollback",
                "participants-rollback",
                "html-rollback"
            ]
        )
        XCTAssertNil(
            registry.reserve(),
            "A superseded transition must leave every account-scoped admission closed"
        )
    }

    func testSignOutWaitsForActiveAccountWorkBeforeResettingStore() async {
        let coordinator = SyncRunCoordinator()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let keychain = MockKeychainService()
        guard let activeRun = await coordinator.beginRun(kind: .pendingActions) else {
            return XCTFail("Expected an active account-scoped run")
        }
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            keychainService: keychain,
            resetCoreDataStore: { cleanup.markStoreReset() },
            syncRunCoordinator: coordinator,
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        // Wait for the durable marker so the assertions below are non-vacuous:
        // the sign-out has provably progressed past intent persistence and
        // admission close while the active run still blocks quiescence.
        await waitUntil {
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        }
        XCTAssertFalse(
            cleanup.storeReset,
            "The persistent store must remain intact while account work owns the boundary"
        )
        XCTAssertTrue(
            session.isAuthenticated,
            "Logged-out UI must not be published until the exclusive account-transition lease is acquired"
        )
        XCTAssertNil(
            outboundTaskRegistry.reserve(),
            "Outbound admission must close before sign-out suspends on the active sync"
        )
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Logout intent must be durable while quiescence is still draining account work"
        )

        await coordinator.endRun(activeRun)
        _ = await signOutTask.value

        XCTAssertTrue(cleanup.storeReset)
        XCTAssertFalse(session.isAuthenticated)
        let nextRun = await coordinator.beginRun(kind: .foregroundInitial)
        XCTAssertNotNil(nextRun, "Sign-out must release quiescence after cleanup")
        if let nextRun {
            await coordinator.endRun(nextRun)
        }
    }

    // Revert-check: the `waitUntil` on the durable marker fails (times out) if
    // `signOut()` moves `persistLocalCleanupRequirement()` back below
    // `beginAuthenticationTransition()` — the sign-out would park on the gate held by
    // the interactive sign-in without ever recording logout intent. The
    // `XCTAssertFalse(cleanup.storeReset)` assertion fails if `signOut()` drops
    // `beginAuthenticationTransition()` entirely and runs its destructive cleanup
    // while the earlier Google transition is still live.
    func testSignOutPersistsIntentWhileWaitingForInteractiveSignInTransition() async {
        let interactiveSignIn = AuthSessionInteractiveSignInGate()
        let keychain = MockKeychainService()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            keychainService: keychain,
            interactiveGoogleSignIn: { _, _, completion in
                interactiveSignIn.begin(completion: completion)
            },
            resetCoreDataStore: { cleanup.markStoreReset() },
            outboundTaskRegistry: OutboundTaskRegistry(admissionOpen: true)
        )
        let signInTask = Task { @MainActor in
            try await session.signIn(presenting: UIViewController())
        }
        await interactiveSignIn.waitUntilStarted()

        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        await waitUntil {
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        }

        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Logout intent must be durable even while an earlier Google transition owns the auth gate"
        )
        XCTAssertFalse(
            cleanup.storeReset,
            "The intent marker must not consume live account state before the earlier transition unwinds"
        )

        interactiveSignIn.cancel()
        do {
            try await signInTask.value
            XCTFail("Expected the injected interactive sign-in cancellation")
        } catch {
            // Expected.
        }
        let signOutResult = await signOutTask.value
        XCTAssertTrue(signOutResult)
        XCTAssertTrue(cleanup.storeReset)
    }

    // Revert-check: fails if `performDurableLocalCleanup(removalRequest:)` drops the
    // no-request branch's `guard pendingAccountRemovalRequests.isEmpty else { throw
    // CancellationError() }`, or if `signOut()` stops calling
    // `registerAccountRemovalRequest()` before `beginAuthenticationTransition()`.
    // The suspended account preparation would then resume, see no pending removal,
    // and delete the marker the queued sign-out just wrote — its own cleanup would
    // be skippable after a crash, and the preparation would wrongly succeed.
    func testQueuedSignOutMarkerSurvivesEarlierSuspendedAccountPreparationCleanup() async {
        let interactiveSignIn = AuthSessionInteractiveSignInGate()
        let resetGate = AuthSessionStoreResetGate()
        let keychain = MockKeychainService()
        let defaults = makeDefaults()
        let session = makeAuthSession(
            keychainService: keychain,
            interactiveGoogleSignIn: { _, _, completion in
                interactiveSignIn.begin(completion: completion)
            },
            userDefaults: defaults,
            resetCoreDataStore: {
                await resetGate.reset()
            },
            fetchStoredAccountEmails: { ["old@example.com"] },
            outboundTaskRegistry: OutboundTaskRegistry(admissionOpen: true)
        )

        // Hold the auth-transition lease in Google UI while an already-started
        // account preparation suspends inside its destructive cleanup.
        let signInTask = Task { @MainActor in
            try await session.signIn(presenting: UIViewController())
        }
        await interactiveSignIn.waitUntilStarted()
        let preparationTask = Task { @MainActor in
            try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")
        }
        await resetGate.waitUntilFirstResetStarted()

        let saveCountBeforeSignOut = keychain.saveCallCount
        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        await waitUntil {
            keychain.saveCallCount > saveCountBeforeSignOut
        }
        XCTAssertGreaterThan(
            keychain.saveCallCount,
            saveCountBeforeSignOut,
            "Sign-out must refresh the durable marker before waiting for the auth-transition lease"
        )

        await resetGate.releaseFirstReset()
        do {
            try await preparationTask.value
            XCTFail("The superseded account preparation should retain the newer sign-out marker")
        } catch let error as AuthError {
            guard case .localAccountIsolationFailed = error else {
                return XCTFail("Unexpected auth error: \(error)")
            }
        } catch {
            XCTFail("Unexpected preparation error: \(error)")
        }

        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Earlier cleanup must not delete the queued sign-out's durable marker"
        )
        XCTAssertTrue(defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))

        interactiveSignIn.cancel()
        do {
            try await signInTask.value
            XCTFail("Expected the injected interactive sign-in cancellation")
        } catch {
            // Expected.
        }
        let signOutResult = await signOutTask.value
        let resetAttemptCount = await resetGate.attemptCount

        XCTAssertTrue(signOutResult)
        XCTAssertEqual(resetAttemptCount, 2)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue))
    }

    // Revert-check: three guards. The marker assertion after the first removal fails
    // if `performDurableLocalCleanup(removalRequest:)` drops its `pendingAccountRemoval
    // Requests.count == 1 && contains(removalRequest)` gate — the first removal would
    // consume the marker the still-queued final removal depends on. The
    // `invocationCount`/`saveTokensCallCount` assertions fail if `signIn(presenting:)`
    // loses its leading `guard !isAccountRemovalRequested else { throw CancellationError() }`,
    // letting the intervening sign-in reach Google UI and persist a session between two
    // removals. Both depend on `endAuthenticationTransition()` resuming waiters FIFO
    // (`removeFirst()`); LIFO reorders which removal reaches the blocked reset.
    func testMultipleQueuedRemovalsBlockInterveningSignInUntilFinalMarkerConsumption() async {
        let interactiveSignIn = AuthSessionSequencedInteractiveSignInGate()
        let resetGate = AuthSessionNthStoreResetGate(blockedAttempt: 2)
        let keychain = MockKeychainService()
        let tokenManager = MockTokenManager()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            interactiveGoogleSignIn: { _, _, completion in
                interactiveSignIn.begin(completion: completion)
            },
            resetCoreDataStore: {
                await resetGate.reset()
            },
            outboundTaskRegistry: OutboundTaskRegistry(admissionOpen: true)
        )

        let activeSignInTask = Task { @MainActor in
            try await session.signIn(presenting: UIViewController())
        }
        await interactiveSignIn.waitUntilFirstStarted()

        let firstRemovalTask = Task { @MainActor in
            await session.signOut()
        }
        await session.waitUntilAuthenticationTransitionWaiterCountForTesting(1)

        let interveningSignInTask = Task { @MainActor in
            try await session.signIn(presenting: UIViewController())
        }
        await session.waitUntilAuthenticationTransitionWaiterCountForTesting(2)

        let finalRemovalTask = Task { @MainActor in
            await session.signOut()
        }
        await session.waitUntilAuthenticationTransitionWaiterCountForTesting(3)

        interactiveSignIn.cancelFirst()
        do {
            try await activeSignInTask.value
            XCTFail("Expected the active interactive sign-in cancellation")
        } catch {
            // Expected.
        }

        // The second reset is the final removal. Reaching this suspension means
        // FIFO transferred through the first removal and intervening sign-in.
        await resetGate.waitUntilBlockedResetStarted()
        let firstRemovalResult = await firstRemovalTask.value
        do {
            try await interveningSignInTask.value
            XCTFail("A queued removal must supersede the intervening sign-in")
        } catch is CancellationError {
            // Expected before Google UI or credential persistence starts.
        } catch {
            XCTFail("Unexpected intervening sign-in error: \(error)")
        }

        XCTAssertTrue(firstRemovalResult)
        XCTAssertEqual(interactiveSignIn.invocationCount, 1)
        XCTAssertEqual(tokenManager.saveTokensCallCount, 0)
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "The first removal must retain the marker while the final removal is pending"
        )

        await resetGate.releaseBlockedReset()
        let finalRemovalResult = await finalRemovalTask.value
        let resetAttemptCount = await resetGate.attemptCount

        XCTAssertTrue(finalRemovalResult)
        XCTAssertEqual(resetAttemptCount, 2)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue))
    }

    func testSignOutAwaitsDownloadDrainBeforeResettingStore() async {
        let downloadDrain = AuthSessionDownloadDrainGate()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            cleanupDownloads: {
                await downloadDrain.waitUntilReleased()
            },
            resetCoreDataStore: { cleanup.markStoreReset() }
        )
        session.isAuthenticated = true

        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        await downloadDrain.waitUntilStarted()

        XCTAssertFalse(
            cleanup.storeReset,
            "Core Data reset must stay behind the attachment writer drain"
        )

        await downloadDrain.release()
        _ = await signOutTask.value

        XCTAssertTrue(cleanup.storeReset)
    }

    func testSignOutAwaitsParticipantCacheDrainBeforeResettingStore() async {
        let participantDrain = AuthSessionDownloadDrainGate()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            clearParticipantCaches: {
                await participantDrain.waitUntilReleased()
            },
            resetCoreDataStore: { cleanup.markStoreReset() }
        )
        session.isAuthenticated = true

        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        await participantDrain.waitUntilStarted()

        XCTAssertFalse(
            cleanup.storeReset,
            "Core Data reset must stay behind the participant-cache writer drain"
        )

        await participantDrain.release()
        _ = await signOutTask.value

        XCTAssertTrue(cleanup.storeReset)
    }

    func testSignOutAwaitsOutboundSendDrainBeforeResettingStore() async {
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let outboundDrain = AuthSessionDownloadDrainGate()
        let cleanup = AuthSessionCleanupRecorder()
        let keychain = MockKeychainService()
        let reservation = try! XCTUnwrap(outboundTaskRegistry.reserve())
        let backgroundTask = Task {
            await outboundDrain.waitUntilReleased()
        }
        XCTAssertTrue(outboundTaskRegistry.handOff(reservation, to: backgroundTask))
        await outboundDrain.waitUntilStarted()

        let session = makeAuthSession(
            keychainService: keychain,
            resetCoreDataStore: { cleanup.markStoreReset() },
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        // Wait for the durable marker so the assertions below are non-vacuous:
        // the sign-out has provably progressed past intent persistence while
        // the admitted send still blocks the outbound drain.
        await waitUntil {
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        }
        XCTAssertFalse(
            cleanup.storeReset,
            "Core Data reset must stay behind the outbound writer drain"
        )
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Logout intent must survive termination without deleting an admitted send's recovery row before its drain"
        )

        await outboundDrain.release()
        _ = await signOutTask.value

        XCTAssertTrue(cleanup.storeReset)
    }

    // Revert-check: fails (the `waitUntil` times out) if `signOutAndDisconnect()`
    // moves `persistLocalCleanupRequirement()` back behind `closeAdmission()` /
    // `beginQuiescence()` / `cancelAndAwaitAll()`. The held outbound reservation
    // blocks that drain, so a crash during an admitted send's reconciliation would
    // leave no durable disconnect intent and the next launch would publish the old
    // account's store instead of resuming cleanup.
    func testDisconnectPersistsIntentBeforeOutboundSendDrain() async throws {
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let outboundDrain = AuthSessionDownloadDrainGate()
        let cleanup = AuthSessionCleanupRecorder()
        let keychain = MockKeychainService()
        let reservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        let backgroundTask = Task {
            await outboundDrain.waitUntilReleased()
        }
        XCTAssertTrue(outboundTaskRegistry.handOff(reservation, to: backgroundTask))
        await outboundDrain.waitUntilStarted()

        let session = makeAuthSession(
            keychainService: keychain,
            resetCoreDataStore: { cleanup.markStoreReset() },
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.accessToken = "old-access-token"
        let disconnectTask = Task { @MainActor in
            try await session.signOutAndDisconnect()
        }
        // The held outbound reservation already guarantees storeReset stays
        // false; what this wait pins is the persist-before-drain ordering —
        // it times out if persistLocalCleanupRequirement() moves back behind
        // cancelAndAwaitAll(), because the blocked drain would then keep the
        // marker from ever appearing.
        await waitUntil {
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue)
        }

        XCTAssertFalse(cleanup.storeReset)
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Disconnect intent must be durable while an admitted send finishes reconciliation"
        )

        await outboundDrain.release()
        try await disconnectTask.value

        XCTAssertTrue(cleanup.storeReset)
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

    private func makeAuthSession(
        tokenManagerProvider: @escaping @MainActor @Sendable () -> TokenManagerProtocol = { MockTokenManager() },
        keychainService: KeychainServiceProtocol = MockKeychainService(),
        hasPreviousGoogleSignIn: @escaping @MainActor @Sendable () -> Bool = { false },
        restorePreviousGoogleSignIn: @escaping @MainActor @Sendable (
            @escaping (GIDGoogleUser?, Error?) -> Void
        ) -> Void = { _ in },
        interactiveGoogleSignIn: @escaping @MainActor @Sendable (
            UIViewController,
            String?,
            @escaping @Sendable (GIDSignInResult?, Error?) -> Void
        ) -> Void = { _, _, _ in },
        signOutGoogleSession: @escaping @MainActor @Sendable () -> Void = {},
        userDefaults: UserDefaults? = nil,
        clearConversationCaches: @escaping @MainActor @Sendable () -> Void = {},
        clearParticipantCaches: @escaping @Sendable () async -> Void = {},
        reopenParticipantCaches: @escaping @Sendable () async -> Void = {},
        cleanupDownloads: @escaping @MainActor @Sendable () async -> Void = {},
        reopenDownloads: @escaping @MainActor @Sendable () async -> Bool = { true },
        resetPendingActionRetryState: @escaping @MainActor @Sendable () async -> Void = {},
        pendingActionAuthenticationDidRecover: @escaping @MainActor @Sendable () async -> Void = {},
        cancelBackgroundTaskRequests: @escaping @MainActor @Sendable () -> Void = {},
        resetCoreDataStore: @escaping @Sendable () async throws -> Void = {},
        fetchStoredAccountEmails: @escaping @Sendable () async throws -> [String] = { [] },
        hasStoredAccountScopedMailboxData: @escaping @Sendable () async throws -> Bool = { false },
        deleteAttachmentFiles: @escaping @Sendable () async throws -> Void = {},
        clearAttachmentCache: @escaping @Sendable () async -> Void = {},
        cleanupHTMLContent: @escaping @MainActor @Sendable () async throws -> Void = {},
        reopenHTMLContent: @escaping @MainActor @Sendable () async throws -> Void = {},
        syncRunCoordinator: SyncRunCoordinator = SyncRunCoordinator(),
        outboundTaskRegistry: OutboundTaskRegistry? = nil,
        revokeGoogleToken: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) -> AuthSession {
        AuthSession(
            tokenManagerProvider: tokenManagerProvider,
            keychainService: keychainService,
            hasPreviousGoogleSignIn: hasPreviousGoogleSignIn,
            restorePreviousGoogleSignIn: restorePreviousGoogleSignIn,
            interactiveGoogleSignIn: interactiveGoogleSignIn,
            signOutGoogleSession: signOutGoogleSession,
            userDefaults: userDefaults ?? makeDefaults(),
            clearConversationCaches: clearConversationCaches,
            clearParticipantCaches: clearParticipantCaches,
            reopenParticipantCaches: reopenParticipantCaches,
            cleanupDownloads: cleanupDownloads,
            reopenDownloads: reopenDownloads,
            resetPendingActionRetryState: resetPendingActionRetryState,
            pendingActionAuthenticationDidRecover: pendingActionAuthenticationDidRecover,
            cancelBackgroundTaskRequests: cancelBackgroundTaskRequests,
            resetCoreDataStore: resetCoreDataStore,
            inspectLocalMailboxStore: {
                LocalMailboxStoreInspection(
                    accountEmails: try await fetchStoredAccountEmails(),
                    hasAccountScopedMailboxData: try await hasStoredAccountScopedMailboxData()
                )
            },
            deleteAttachmentFiles: deleteAttachmentFiles,
            clearAttachmentCache: clearAttachmentCache,
            cleanupHTMLContent: cleanupHTMLContent,
            reopenHTMLContent: reopenHTMLContent,
            syncRunCoordinator: syncRunCoordinator,
            outboundTaskRegistry: outboundTaskRegistry ?? OutboundTaskRegistry(),
            revokeGoogleToken: revokeGoogleToken
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AuthSessionTests.\(UUID().uuidString)")!
    }
}

private final class AuthSessionStoreResetScript: @unchecked Sendable {
    private struct ResetFailure: Error {}

    private let lock = NSLock()
    private var remainingFailures: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int = 0) {
        remainingFailures = failuresBeforeSuccess
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func reset() throws {
        lock.lock()
        attempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            lock.unlock()
            throw ResetFailure()
        }
        lock.unlock()
    }
}

private final class AuthSessionFileCleanupScript: @unchecked Sendable {
    private struct DeleteFailure: Error {}
    private let lock = NSLock()
    private var remainingFailures: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        remainingFailures = failuresBeforeSuccess
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func deleteFiles() throws {
        lock.lock()
        attempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            lock.unlock()
            throw DeleteFailure()
        }
        lock.unlock()
    }
}

private final class AuthSessionHTMLCleanupScript: @unchecked Sendable {
    private struct CleanupFailure: Error {}
    private let lock = NSLock()
    private var remainingFailures: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        remainingFailures = failuresBeforeSuccess
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func cleanup() throws {
        lock.lock()
        attempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            lock.unlock()
            throw CleanupFailure()
        }
        lock.unlock()
    }
}

private actor AuthSessionTokenRevocationGate {
    private let recorder: AuthSessionCleanupRecorder
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var revokedToken: String?

    init(recorder: AuthSessionCleanupRecorder) {
        self.recorder = recorder
    }

    func revoke(_ token: String) async throws {
        revokedToken = token
        started = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        recorder.record("disconnect")
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}

private final class RecordingTokenManager: TokenManagerProtocol, @unchecked Sendable {
    private let onClear: @Sendable () -> Void

    init(onClear: @escaping @Sendable () -> Void) {
        self.onClear = onClear
    }

    func saveTokens(access: String, refresh: String?, expirationDate: Date) throws {}
    func getCurrentToken() async throws -> String { "token" }
    func refreshToken() async throws -> String { "token" }
    func clearTokens() throws { onClear() }
    func isAuthenticated() -> Bool { true }
}

private actor AuthSessionDownloadDrainGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !released else { return }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AuthSessionStoreResetGate {
    private var attempts = 0
    private var firstResetStarted = false
    private var firstResetReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var attemptCount: Int { attempts }

    func reset() async {
        attempts += 1
        guard attempts == 1 else { return }

        firstResetStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        guard !firstResetReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilFirstResetStarted() async {
        guard !firstResetStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstReset() {
        firstResetReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}

private actor AuthSessionNthStoreResetGate {
    private let blockedAttempt: Int
    private var attempts = 0
    private var blockedResetStarted = false
    private var blockedResetReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedAttempt: Int) {
        self.blockedAttempt = blockedAttempt
    }

    var attemptCount: Int { attempts }

    func reset() async {
        attempts += 1
        guard attempts == blockedAttempt else { return }

        blockedResetStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        guard !blockedResetReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlockedResetStarted() async {
        guard !blockedResetStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBlockedReset() {
        blockedResetReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class AuthSessionInteractiveSignInGate {
    private var completion: (@Sendable (GIDSignInResult?, Error?) -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func begin(
        completion: @escaping @Sendable (GIDSignInResult?, Error?) -> Void
    ) {
        self.completion = completion
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func cancel() {
        let completion = completion
        self.completion = nil
        completion?(
            nil,
            NSError(domain: kGIDSignInErrorDomain, code: -5)
        )
    }
}

@MainActor
private final class AuthSessionSequencedInteractiveSignInGate {
    private var firstCompletion: (@Sendable (GIDSignInResult?, Error?) -> Void)?
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var invocationCount = 0

    func begin(
        completion: @escaping @Sendable (GIDSignInResult?, Error?) -> Void
    ) {
        invocationCount += 1
        guard invocationCount == 1 else {
            completion(nil, NSError(domain: kGIDSignInErrorDomain, code: -5))
            return
        }

        firstCompletion = completion
        let waiters = firstStartWaiters
        firstStartWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilFirstStarted() async {
        guard firstCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func cancelFirst() {
        let completion = firstCompletion
        firstCompletion = nil
        completion?(nil, NSError(domain: kGIDSignInErrorDomain, code: -5))
    }
}

@MainActor
private final class AuthSessionTokenManagerFactory: @unchecked Sendable {
    private(set) var createdManagers: [MockTokenManager] = []

    func makeDistinctTokenManager() -> TokenManagerProtocol {
        let manager = MockTokenManager()
        manager.currentToken = "token-\(createdManagers.count + 1)"
        createdManagers.append(manager)
        return manager
    }
}

@MainActor
private final class TokenManagerProvider: @unchecked Sendable {
    var tokenManager: TokenManager!
}

private final class AuthSessionCleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _storeReset = false
    private var _conversationCachesCleared = false
    private var _participantCachesCleared = false
    private var _downloadsCleared = false
    private var _downloadsReopened = false
    private var _attachmentFilesCleared = false
    private var _attachmentCacheCleared = false
    private var _events: [String] = []

    var storeReset: Bool { withLock { _storeReset } }
    var conversationCachesCleared: Bool { withLock { _conversationCachesCleared } }
    var participantCachesCleared: Bool { withLock { _participantCachesCleared } }
    var downloadsCleared: Bool { withLock { _downloadsCleared } }
    var downloadsReopened: Bool { withLock { _downloadsReopened } }
    var attachmentFilesCleared: Bool { withLock { _attachmentFilesCleared } }
    var attachmentCacheCleared: Bool { withLock { _attachmentCacheCleared } }
    var events: [String] { withLock { _events } }

    func markStoreReset() { withLock { _storeReset = true } }
    func markConversationCachesCleared() { withLock { _conversationCachesCleared = true } }
    func markParticipantCachesCleared() { withLock { _participantCachesCleared = true } }
    func markDownloadsCleared() { withLock { _downloadsCleared = true } }
    func markDownloadsReopened() { withLock { _downloadsReopened = true } }
    func markAttachmentFilesCleared() { withLock { _attachmentFilesCleared = true } }
    func markAttachmentCacheCleared() { withLock { _attachmentCacheCleared = true } }
    func record(_ event: String) { withLock { _events.append(event) } }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
