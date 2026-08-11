import GoogleSignIn
import XCTest
@testable import esc_chatmail

@MainActor
final class AuthSessionTests: XCTestCase {
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
        let keychain = MockKeychainService()
        let tokenManagerProvider = TokenManagerProvider()
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManagerProvider.tokenManager },
            keychainService: keychain
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
            reopenDownloads: { cleanup.record("downloads-reopened") },
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
            reopenDownloads: { cleanup.record("downloads-reopened") },
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
            reopenDownloads: { cleanup.record("downloads-reopened") },
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["first@example.com"] },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            outboundTaskRegistry: registry
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("SECOND@example.com")
        let didReopen = await session.reopenAccountWork(after: transition)

        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertTrue(didReopen)
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
            reopenDownloads: { cleanup.markDownloadsReopened() },
            fetchStoredAccountEmails: { [] },
            outboundTaskRegistry: registry
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")

        let didReopen = await session.reopenAccountWork(after: transition)
        XCTAssertTrue(didReopen)
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

        let didReopen = await session.reopenAccountWork(after: transition)

        XCTAssertFalse(didReopen)
        XCTAssertEqual(
            cleanup.events,
            ["html-partially-reopened", "html-rollback"]
        )
        XCTAssertNil(
            registry.reserve(),
            "Outbound work must remain closed when HTML admission cannot be reopened atomically"
        )
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
            reopenDownloads: { cleanup.record("downloads-reopened") },
            cleanupHTMLContent: { cleanup.record("html-rollback") },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            outboundTaskRegistry: registry
        )

        let didReopen = await session.reopenAccountWork(after: staleTransition)

        XCTAssertFalse(didReopen)
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
        guard let activeRun = await coordinator.beginRun(kind: .pendingActions) else {
            return XCTFail("Expected an active account-scoped run")
        }
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            resetCoreDataStore: { cleanup.markStoreReset() },
            syncRunCoordinator: coordinator,
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        for _ in 0..<20 {
            await Task.yield()
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
        let reservation = try! XCTUnwrap(outboundTaskRegistry.reserve())
        let backgroundTask = Task {
            await outboundDrain.waitUntilReleased()
        }
        XCTAssertTrue(outboundTaskRegistry.handOff(reservation, to: backgroundTask))
        await outboundDrain.waitUntilStarted()

        let session = makeAuthSession(
            resetCoreDataStore: { cleanup.markStoreReset() },
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        let signOutTask = Task { @MainActor in
            await session.signOut()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            cleanup.storeReset,
            "Core Data reset must stay behind the outbound writer drain"
        )

        await outboundDrain.release()
        _ = await signOutTask.value

        XCTAssertTrue(cleanup.storeReset)
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
        reopenDownloads: @escaping @MainActor @Sendable () async -> Void = {},
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
