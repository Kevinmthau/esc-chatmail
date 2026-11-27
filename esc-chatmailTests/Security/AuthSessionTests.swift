import GoogleSignIn
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
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

    // `SyncEngine.shared` outlives sign-out, so the previous account's full-disk backoff and
    // banner used to carry into the next account. Both sign-out paths retire them, inside the
    // transition and before the store is reset.
    // Revert-check: fails if the `resetSyncStorageState()` calls are removed from
    // AuthSession.signOut() and signOutAndDisconnect() (firstIndex(of:) goes nil).
    // HONEST SCOPE: the sign-in and restore calls sit on paths that publish a GIDGoogleUser, which
    // these tests cannot construct, so only the two sign-out paths are pinned here.
    func testSignOutPaths_resetSyncStorageStateBeforeStoreCleanup() async {
        for disconnects in [false, true] {
            let cleanup = AuthSessionCleanupRecorder()
            let session = makeAuthSession(
                resetSyncStorageState: { cleanup.record("sync-storage-reset") },
                resetCoreDataStore: { cleanup.record("store-reset") }
            )
            session.isAuthenticated = true

            if disconnects {
                // No user means no revocation token: disconnect throws after its local cleanup.
                try? await session.signOutAndDisconnect()
            } else {
                let didSignOut = await session.signOut()
                XCTAssertTrue(didSignOut)
            }

            let path = disconnects ? "signOutAndDisconnect" : "signOut"
            let storageResetIndex = cleanup.events.firstIndex(of: "sync-storage-reset")
            let storeResetIndex = cleanup.events.firstIndex(of: "store-reset")
            XCTAssertNotNil(storageResetIndex, "\(path) must reset the sync storage state")
            XCTAssertNotNil(storeResetIndex, "\(path) must reset the store")
            if let storageResetIndex, let storeResetIndex {
                XCTAssertLessThan(storageResetIndex, storeResetIndex, path)
            }
        }
    }

    // Both sign-out paths drop the alias caches through the one injected closure, ahead of
    // the store cleanup as before, and the cleanup drops them again after the store reset,
    // as every store reset does.
    // Revert-check: fails if a path keeps an inline `AliasManager.shared.invalidate()` pair
    // in place of the closure (no event before the reset), or if
    // `performDurableLocalCleanup` loses its call (no event after it).
    func testSignOutPaths_invalidateAliasCachesThroughTheClosure_beforeAndAfterTheStoreReset() async {
        for disconnects in [false, true] {
            let cleanup = AuthSessionCleanupRecorder()
            let session = makeAuthSession(
                invalidateAccountAliasCaches: { cleanup.record("alias-caches-invalidated") },
                resetCoreDataStore: { cleanup.record("store-reset") }
            )
            session.isAuthenticated = true

            if disconnects {
                // No user means no revocation token: disconnect throws after its local cleanup.
                try? await session.signOutAndDisconnect()
            } else {
                let didSignOut = await session.signOut()
                XCTAssertTrue(didSignOut)
            }

            let path = disconnects ? "signOutAndDisconnect" : "signOut"
            let storeResetIndex = cleanup.events.firstIndex(of: "store-reset")
            let invalidations = cleanup.events.indices.filter { cleanup.events[$0] == "alias-caches-invalidated" }
            XCTAssertNotNil(storeResetIndex, "\(path) must reset the store")
            XCTAssertEqual(invalidations.count, 2, "\(path): once at the path, once in the cleanup")
            if let storeResetIndex, invalidations.count == 2 {
                XCTAssertLessThan(invalidations[0], storeResetIndex, path)
                XCTAssertGreaterThan(invalidations[1], storeResetIndex, path)
            }
        }
    }

    // The two crash-resume paths drop the alias caches through the same closure.
    // Revert-check: fails if the credential-cleanup resume keeps an inline invalidation pair
    // in place of the closure (it reaches no other call). The removal resume reaches
    // `performDurableLocalCleanup`, whose own call records an event, so an inline pair
    // there is caught only by `testAliasCacheInvalidation_goesThroughTheSeamOnly`.
    func testRestoreResumedCleanup_invalidatesAliasCachesThroughTheClosure() async throws {
        for key in [KeychainService.Key.localStoreResetRequired, .credentialCleanupRequired] {
            let keychain = MockKeychainService()
            try keychain.save(Data([1]), for: key.rawValue, withAccess: .afterFirstUnlockThisDeviceOnly)
            let cleanup = AuthSessionCleanupRecorder()
            let session = makeAuthSession(
                keychainService: keychain,
                invalidateAccountAliasCaches: { cleanup.record("alias-caches-invalidated") }
            )

            let outcome = await session.restorePreviousSignIn()

            XCTAssertEqual(outcome, .terminalNoSession, key.rawValue)
            XCTAssertFalse(
                cleanup.events.filter { $0 == "alias-caches-invalidated" }.isEmpty,
                "\(key.rawValue): the resumed cleanup drops the alias caches"
            )
        }
    }

    // In AuthSession.swift the alias caches are invalidated only through the injected
    // closure, whose production default is `ProductionAliasCacheAccountTransition`: no
    // path keeps an inline pair, which is how the sign-in over another account's store
    // was missed. Comment lines are skipped.
    // Revert-check: fails if an `AliasManager.shared.invalidate()` or
    // `SendAsAliasManager.shared.invalidate()` is added to AuthSession.swift outside that
    // namespace.
    func testAliasCacheInvalidation_goesThroughTheSeamOnly() throws {
        let source = try repositorySource("esc-chatmail/Services/Security/AuthSession.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // With the `await`: the first spelling is also the tail of the second.
        for call in ["await AliasManager.shared.invalidate()", "await SendAsAliasManager.shared.invalidate()"] {
            XCTAssertEqual(source.components(separatedBy: call).count - 1, 1, call)
        }
        let namespace = try XCTUnwrap(source.range(of: "private enum ProductionAliasCacheAccountTransition {"))
        let callSite = try XCTUnwrap(source.range(of: "await AliasManager.shared.invalidate()"))
        XCTAssertLessThan(namespace.lowerBound, callSite.lowerBound)
        XCTAssertLessThan(
            source.distance(from: namespace.upperBound, to: callSite.lowerBound),
            80,
            "The one invalidation pair is the body of the production namespace"
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "await invalidateAccountAliasCaches()").count - 1,
            5,
            "The four removal paths and performDurableLocalCleanup call the closure"
        )
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
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.durableSignedOut.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
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
        XCTAssertFalse(
            keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue),
            "A fully persisted replacement session must consume the signed-out verdict"
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

    func testRestoreDurableSignedOutStateRejectsSurvivingSDKSession() async throws {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "signed-out@example.com"
        ])
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.durableSignedOut.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        let tokenManager = MockTokenManager()
        let cleanup = AuthSessionCleanupRecorder()
        var restoreCallCount = 0
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            hasPreviousGoogleSignIn: { true },
            googleSignInKeychainPresence: { .present },
            restorePreviousGoogleSignIn: { completion in
                restoreCallCount += 1
                completion(nil, NSError(domain: kGIDSignInErrorDomain, code: -4))
            },
            signOutGoogleSession: { cleanup.record("google-sign-out") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(restoreCallCount, 0, "Durable sign-out must win before SDK restore")
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue))
        XCTAssertEqual(cleanup.events, ["google-sign-out"])
    }

    func testRestorePublicSDKAbsenceWithIndeterminateRawQueryIsRetryable() async {
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            hasPreviousGoogleSignIn: { false },
            googleSignInKeychainPresence: { .indeterminate },
            restorePreviousGoogleSignIn: { _ in cleanup.record("google-restore") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertTrue(cleanup.events.isEmpty)
    }

    func testRestoreDefinitiveSDKAbsenceClearsOrphanedAppCredentialsWithoutSDKRestore() async {
        let keychain = MockKeychainService()
        keychain.preloadStrings([
            KeychainService.Key.googleUserEmail.rawValue: "orphaned@example.com"
        ])
        let tokenManager = MockTokenManager()
        let cleanup = AuthSessionCleanupRecorder()
        var restoreCallCount = 0
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            hasPreviousGoogleSignIn: { false },
            googleSignInKeychainPresence: { .absent },
            restorePreviousGoogleSignIn: { _ in restoreCallCount += 1 },
            signOutGoogleSession: { cleanup.record("google-sign-out") },
            cancelBackgroundTaskRequests: { cleanup.record("background-cancel") }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(restoreCallCount, 0)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue))
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue))
        XCTAssertTrue(cleanup.events.contains("google-sign-out"))
        XCTAssertEqual(cleanup.events.filter { $0 == "background-cancel" }.count, 2)
    }

    func testRestoreDefinitiveSDKAbsenceWithoutAppCredentialsKeepsFastTerminalPath() async {
        let keychain = MockKeychainService()
        let tokenManager = MockTokenManager()
        var restoreCallCount = 0
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            hasPreviousGoogleSignIn: { false },
            googleSignInKeychainPresence: { .absent },
            restorePreviousGoogleSignIn: { _ in restoreCallCount += 1 }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(restoreCallCount, 0)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 0)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.credentialCleanupRequired.rawValue))
    }

    func testRestorePublicSDKAbsenceWithPresentRawItemClassifiesSDKError() async {
        let keychain = MockKeychainService()
        let tokenManager = MockTokenManager()
        var restoreCallCount = 0
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain,
            hasPreviousGoogleSignIn: { false },
            googleSignInKeychainPresence: { .present },
            restorePreviousGoogleSignIn: { completion in
                restoreCallCount += 1
                completion(nil, NSError(domain: kGIDSignInErrorDomain, code: -4))
            }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertEqual(restoreCallCount, 1)
        XCTAssertEqual(tokenManager.clearTokensCallCount, 1)
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue))
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
            try await session.signIn(presenting: makePresentationAnchor())
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
            try await session.signIn(presenting: makePresentationAnchor())
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
            try await session.signIn(presenting: makePresentationAnchor())
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

    // Revert-check: fails if reopenPreSignInAccountWork(after:)'s
    // undrained-sends leg starts rolling back downloads and participant caches
    // the way its superseded leg does — the recorded events grow the two
    // rollback entries the assertion excludes. No newer transition exists
    // whose teardown that rollback would protect; it would only strip a live,
    // published session of the capabilities it retains on top of the send
    // latch it already suffers.
    //
    // HONEST SCOPE: the undrained entry is manufactured by re-adopting an
    // already-finished reservation via handOff(_:to:) from the injected
    // cleanupDownloads closure, after signIn's cancelAndAwaitAll() has
    // drained. No production caller reuses a finished reservation, and
    // signIn's own drain makes this state unreachable through real send
    // flows.
    func testPreSignInReopenDegradesInsteadOfRollingBackWhenSendsAreUndrained() async throws {
        let cleanup = AuthSessionCleanupRecorder()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let finishedReservation = try XCTUnwrap(outboundTaskRegistry.reserve())
        outboundTaskRegistry.finish(finishedReservation)
        let leakGate = AuthSessionDownloadDrainGate()
        let leakedTask = Task { await leakGate.waitUntilReleased() }
        let cancellation = NSError(domain: kGIDSignInErrorDomain, code: -5)
        let session = makeAuthSession(
            interactiveGoogleSignIn: { _, _, completion in
                completion(nil, cancellation)
            },
            clearParticipantCaches: { cleanup.record("participants-closed") },
            reopenParticipantCaches: { cleanup.record("participants-reopened") },
            cleanupDownloads: { @MainActor in
                cleanup.record("downloads-closed")
                // Runs after signIn's cancelAndAwaitAll() has drained, so this
                // plants the undrained entry the outbound reopen will find.
                outboundTaskRegistry.handOff(finishedReservation, to: leakedTask)
            },
            reopenDownloads: {
                cleanup.record("downloads-reopened")
                return true
            },
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        do {
            try await session.signIn(presenting: makePresentationAnchor())
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
            ],
            "An undrained send must degrade the pre-sign-in reopen, not widen it into the superseded rollback"
        )
        XCTAssertTrue(session.isAuthenticated)
        // Bind-and-finish the probe: a non-nil result is already a failure,
        // and leaving its entry in the table would park the trailing
        // cancelAndAwaitAll() forever, turning that failure into a suite hang.
        let latchProbe = outboundTaskRegistry.reserve()
        XCTAssertNil(
            latchProbe,
            "Outbound admission stays latched while the leaked send is outstanding"
        )
        if let latchProbe {
            outboundTaskRegistry.finish(latchProbe)
        }

        await leakGate.release()
        await outboundTaskRegistry.cancelAndAwaitAll()
    }

    // Revert-check: fails if reopenPreSignInAccountWork(after:)'s
    // .supersededByNewerTransition leg stops rolling back downloads and
    // participant caches — e.g. it collapses into the undrained-sends degrade
    // leg or a bare break. A failed sign-in superseded by a queued sign-out
    // would then leave the stale account's downloads and caches admitted
    // while the sign-out's teardown runs.
    func testPreSignInReopenRollsBackWhenSupersededByQueuedSignOut() async {
        let cleanup = AuthSessionCleanupRecorder()
        let outboundTaskRegistry = OutboundTaskRegistry(admissionOpen: true)
        let cancellation = NSError(domain: kGIDSignInErrorDomain, code: -5)
        let session = makeAuthSession(
            interactiveGoogleSignIn: { _, _, completion in
                completion(nil, cancellation)
            },
            clearParticipantCaches: { cleanup.record("participants-closed") },
            reopenParticipantCaches: { cleanup.record("participants-reopened") },
            cleanupDownloads: { @MainActor in
                cleanup.record("downloads-closed")
                // Model a sign-out queueing behind the auth gate mid-sign-in:
                // its closeAdmission() runs synchronously pre-gate and bumps
                // the generation, superseding this sign-in's token.
                outboundTaskRegistry.closeAdmission()
            },
            reopenDownloads: {
                cleanup.record("downloads-reopened")
                return true
            },
            outboundTaskRegistry: outboundTaskRegistry
        )
        session.isAuthenticated = true

        do {
            try await session.signIn(presenting: makePresentationAnchor())
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
                "downloads-reopened",
                "downloads-closed",
                "participants-closed"
            ],
            "A superseded pre-sign-in reopen must roll back every stale account-work reopen"
        )
        XCTAssertNil(
            outboundTaskRegistry.reserve(),
            "Admission belongs to the superseding transition and must stay closed"
        )
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
        XCTAssertEqual(outboundTaskRegistry.reopenAdmission(after: interactiveTransition), .reopened)
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
            try await session.signIn(presenting: makePresentationAnchor())
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

    func testDurableSignOutVerdict_activeInteractiveSignInFailsSafe() async throws {
        let interactiveSignIn = AuthSessionInteractiveSignInGate()
        let keychain = MockKeychainService()
        let cleanup = AuthSessionCleanupRecorder()
        try keychain.save(
            Data([1]),
            for: KeychainService.Key.durableSignedOut.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        let session = makeAuthSession(
            keychainService: keychain,
            interactiveGoogleSignIn: { _, _, completion in
                interactiveSignIn.begin(completion: completion)
            },
            cancelBackgroundTaskRequests: { cleanup.record("background-cancel") },
            outboundTaskRegistry: OutboundTaskRegistry(admissionOpen: true)
        )
        let signInTask = Task { @MainActor in
            try await session.signIn(presenting: makePresentationAnchor())
        }
        await interactiveSignIn.waitUntilStarted()

        XCTAssertFalse(
            session.isDurablySignedOut(),
            "A transition that can still publish a session must remain indeterminate"
        )
        XCTAssertTrue(cleanup.events.isEmpty)

        interactiveSignIn.cancel()
        do {
            try await signInTask.value
            XCTFail("Expected the injected interactive sign-in cancellation")
        } catch {
            // Expected.
        }
        XCTAssertTrue(session.isDurablySignedOut())
        XCTAssertEqual(cleanup.events, ["background-cancel"])
    }

    func testQueuedTerminalRestoreSweepsWhenFinalAuthenticationTransitionEnds() async {
        let interactiveSignIn = AuthSessionInteractiveSignInGate()
        let cleanup = AuthSessionCleanupRecorder()
        let session = makeAuthSession(
            interactiveGoogleSignIn: { _, _, completion in
                interactiveSignIn.begin(completion: completion)
            },
            cancelBackgroundTaskRequests: { cleanup.record("background-cancel") },
            outboundTaskRegistry: OutboundTaskRegistry(admissionOpen: true)
        )
        let signInTask = Task { @MainActor in
            try await session.signIn(presenting: makePresentationAnchor())
        }
        await interactiveSignIn.waitUntilStarted()

        let restoreTask = Task { @MainActor in
            await session.restorePreviousSignIn()
        }
        await session.waitUntilAuthenticationTransitionWaiterCountForTesting(1)
        interactiveSignIn.cancel()

        do {
            try await signInTask.value
            XCTFail("Expected the injected interactive sign-in cancellation")
        } catch {
            // Expected.
        }
        let restoreOutcome = await restoreTask.value
        XCTAssertEqual(restoreOutcome, .terminalNoSession)
        XCTAssertTrue(session.isDurablySignedOut())
        XCTAssertEqual(
            cleanup.events,
            ["background-cancel"],
            "Only the final transition owner may sweep the stale re-arm"
        )
    }

    func testQueuedRetryableCleanupRestoreSweepsWhenDurableMarkerSaveFails() async throws {
        struct MarkerSaveFailure: Error {}

        for marker in [
            KeychainService.Key.localStoreResetRequired,
            KeychainService.Key.credentialCleanupRequired
        ] {
            let interactiveSignIn = AuthSessionInteractiveSignInGate()
            let cleanup = AuthSessionCleanupRecorder()
            let keychain = MockKeychainService()
            try keychain.save(
                Data([1]),
                for: marker.rawValue,
                withAccess: .afterFirstUnlockThisDeviceOnly
            )
            keychain.failNextSave(
                for: KeychainService.Key.durableSignedOut.rawValue,
                with: MarkerSaveFailure()
            )
            let session = makeAuthSession(
                keychainService: keychain,
                interactiveGoogleSignIn: { _, _, completion in
                    interactiveSignIn.begin(completion: completion)
                },
                cancelBackgroundTaskRequests: { cleanup.record("background-cancel") },
                outboundTaskRegistry: OutboundTaskRegistry(admissionOpen: true)
            )
            let signInTask = Task { @MainActor in
                try await session.signIn(presenting: makePresentationAnchor())
            }
            await interactiveSignIn.waitUntilStarted()

            let restoreTask = Task { @MainActor in
                await session.restorePreviousSignIn()
            }
            await session.waitUntilAuthenticationTransitionWaiterCountForTesting(1)
            interactiveSignIn.cancel()

            do {
                try await signInTask.value
                XCTFail("Expected the injected interactive sign-in cancellation")
            } catch {
                // Expected.
            }
            let restoreOutcome = await restoreTask.value
            XCTAssertEqual(restoreOutcome, .retryableFailure, "Marker: \(marker.rawValue)")
            XCTAssertTrue(session.isDurablySignedOut(), "Marker: \(marker.rawValue)")
            XCTAssertEqual(
                cleanup.events,
                ["background-cancel"],
                "Confirmed cleanup intent must sweep even when marker migration fails: \(marker.rawValue)"
            )
            XCTAssertTrue(keychain.exists(for: marker.rawValue))
            XCTAssertFalse(
                keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue)
            )
        }
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

    func testSignOutDurableStateHandoffFailureKeepsAcceptedRemovalRecoverable() async {
        struct DurableStatePersistenceFailure: Error {}
        let keychain = MockKeychainService()
        keychain.failNextSave(
            for: KeychainService.Key.durableSignedOut.rawValue,
            with: DurableStatePersistenceFailure()
        )
        let session = makeAuthSession(keychainService: keychain)
        session.isAuthenticated = true
        session.userEmail = "person@example.com"

        let accepted = await session.signOut()

        XCTAssertTrue(accepted, "The first cleanup marker already committed removal intent")
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue))
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue))

        let recoverySession = makeAuthSession(keychainService: keychain)
        let outcome = await recoverySession.restorePreviousSignIn()

        XCTAssertEqual(outcome, .terminalNoSession)
        XCTAssertFalse(keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue))
        XCTAssertTrue(keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue))
    }

    // Revert-check: fails if `signOut()` drops its `cancelBackgroundTaskRequests()`
    // step. Without it the pending com.esc.inboxchat.refresh/.processing requests
    // survive sign-out, and each fire re-arms itself at handler entry before the
    // unauthenticated guard runs, so a signed-out device takes discretionary
    // background wakes indefinitely.
    func testSignOutCancelsPendingBackgroundTaskRequestsEvenWhenStoreResetFails() async {
        struct StoreResetFailure: Error {}
        let cleanup = AuthSessionCleanupRecorder()
        let keychain = MockKeychainService()
        let session = makeAuthSession(
            keychainService: keychain,
            cancelBackgroundTaskRequests: { cleanup.record("bg-task-requests-cancelled") },
            resetCoreDataStore: { throw StoreResetFailure() }
        )

        await session.signOut()

        XCTAssertEqual(
            cleanup.events,
            [
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled"
            ],
            "Sign-out must sweep before, during, and after its suspending cleanup"
        )
        XCTAssertTrue(
            keychain.exists(for: KeychainService.Key.localStoreResetRequired.rawValue),
            "Failed cleanup must retain its original durable recovery marker"
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
            [
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled"
            ],
            "Disconnect must sweep before, during, and after its suspending cleanup"
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
        XCTAssertEqual(
            cleanup.events,
            [
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled"
            ]
        )
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
        XCTAssertEqual(
            cleanup.events,
            [
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled",
                "bg-task-requests-cancelled"
            ]
        )
    }

    // The crash-resume pair signs Google out through the injected seam, in its place in
    // the teardown: after the drains, before the downloads close. It called the SDK
    // singleton directly, which no stub covered, and in a Mac test host that would delete
    // the installed MushMail's Google keychain item (inferred, not measured; architecture
    // review 2026-11, account-boundary-auth#5).
    // Revert-check: fails if `resumeInterruptedAccountRemovalIfNeeded()` or
    // `resumeInterruptedCredentialCleanupIfNeeded()` goes back to
    // `GIDSignIn.sharedInstance.signOut()` in place of `signOutGoogleSession()`
    // (no "google-sign-out" is recorded for that marker). Run that revert-check on the iOS
    // simulator only: reverted, a Mac test host would delete the installed app's Google
    // session, which is the damage this test exists to prevent.
    func testRestoreResumedCleanup_signsGoogleOutThroughTheSeamBeforeDownloadsClose() async throws {
        for key in [KeychainService.Key.localStoreResetRequired, .credentialCleanupRequired] {
            let keychain = MockKeychainService()
            try keychain.save(Data([1]), for: key.rawValue, withAccess: .afterFirstUnlockThisDeviceOnly)
            let cleanup = AuthSessionCleanupRecorder()
            let session = makeAuthSession(
                keychainService: keychain,
                signOutGoogleSession: { cleanup.record("google-sign-out") },
                clearParticipantCaches: { cleanup.record("participants-closed") },
                cleanupDownloads: { cleanup.record("downloads-closed") }
            )

            let outcome = await session.restorePreviousSignIn()

            XCTAssertEqual(outcome, .terminalNoSession, key.rawValue)
            // The participant drain is the last one before the sign-out.
            XCTAssertEqual(
                cleanup.events
                    .filter { ["participants-closed", "google-sign-out", "downloads-closed"].contains($0) }
                    .prefix(3),
                ["participants-closed", "google-sign-out", "downloads-closed"],
                key.rawValue
            )
            XCTAssertEqual(cleanup.events.filter { $0 == "google-sign-out" }.count, 1, key.rawValue)
        }
    }

    // In AuthSession.swift the SDK's sign-out is called only as the seam's production
    // default, and its disconnect not at all, so neither reaches the real Google session
    // past a test's stub. Comment lines are skipped, so a note may quote the call.
    // HONEST SCOPE: this reads one spelling; an alias of the singleton would slip past.
    // Revert-check: fails if a `GIDSignIn.sharedInstance.signOut()` or `.disconnect` is
    // added to AuthSession.swift outside the `signOutGoogleSession` default.
    func testGoogleSDKSignOut_isCalledOnlyFromTheSeamDefault() throws {
        let fullSource = try repositorySource("esc-chatmail/Services/Security/AuthSession.swift")
        let source = fullSource
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let call = "GIDSignIn.sharedInstance.signOut()"
        XCTAssertEqual(source.components(separatedBy: call).count - 1, 1)
        XCTAssertFalse(source.contains("GIDSignIn.sharedInstance.disconnect"))
        let seamDefault = try XCTUnwrap(source.range(of: "signOutGoogleSession: @escaping @MainActor @Sendable () -> Void = {"))
        let callSite = try XCTUnwrap(source.range(of: call))
        XCTAssertLessThan(seamDefault.lowerBound, callSite.lowerBound)
        XCTAssertLessThan(
            source.distance(from: seamDefault.upperBound, to: callSite.lowerBound),
            40,
            "The one SDK sign-out is the body of the seam's default closure"
        )
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
        XCTAssertEqual(
            cleanup.events,
            ["bg-task-requests-cancelled", "bg-task-requests-cancelled"]
        )
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
    // account over a store whose pending reset could not be proven absent. The stage
    // assertion fails if that catch throws another stage than `.markerUnreadable`, which
    // a launch restore reads as "nothing was changed" (`AuthRestorePreparationPolicy`),
    // and the keychain assertions if anything is written before it.
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

        let stage = await isolationStage(thrownBy: {
            try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")
        })

        XCTAssertEqual(stage, .markerUnreadable, "An indeterminate marker read must block account publication")
        XCTAssertEqual(resetScript.attemptCount, 0)
        XCTAssertEqual(keychain.saveCallCount, 0, "Nothing is written before the marker is read")
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    // MARK: - Account preparation stages (architecture review 2026-11, account-boundary-auth#4)

    // Revert-check: fails if the `inspectLocalMailboxStore()` catch of
    // `prepareLocalStoreForAuthenticatedAccount` throws another stage than
    // `.storeUninspectable`, or if anything is written to the keychain before the store
    // has been inspected.
    func testAccountPreparation_storeInspectionFails_throwsStoreUninspectableWithoutKeychainWrite() async {
        struct InspectionFailure: Error {}
        let keychain = MockKeychainService()
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            keychainService: keychain,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { throw InspectionFailure() }
        )

        let stage = await isolationStage(thrownBy: {
            try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")
        })

        XCTAssertEqual(stage, .storeUninspectable)
        XCTAssertEqual(resetScript.attemptCount, 0)
        XCTAssertEqual(keychain.saveCallCount, 0)
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    // Revert-check: fails if the persistence of the reset marker goes back into the
    // reset's own do/catch (it then throws `.resetFailed`), or its catch throws another
    // stage than `.resetRequired`.
    func testAccountPreparation_resetMarkerCannotBeWritten_throwsResetRequiredBeforeTheReset() async {
        struct MarkerWriteFailure: Error {}
        let keychain = MockKeychainService()
        keychain.failNextSave(
            for: KeychainService.Key.localStoreResetRequired.rawValue,
            with: MarkerWriteFailure()
        )
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            keychainService: keychain,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        let stage = await isolationStage(thrownBy: {
            try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")
        })

        XCTAssertEqual(stage, .resetRequired)
        XCTAssertEqual(resetScript.attemptCount, 0, "No reset runs without its durable marker")
    }

    // Revert-check: fails if a failed `performDurableLocalCleanup()` in
    // `prepareLocalStoreForAuthenticatedAccount` is thrown under another stage than
    // `.resetFailed`.
    func testAccountPreparation_storeResetFails_throwsResetFailed() async {
        let resetScript = AuthSessionStoreResetScript(failuresBeforeSuccess: 1)
        let session = makeAuthSession(
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        let stage = await isolationStage(thrownBy: {
            try await session.prepareLocalStoreForAuthenticatedAccount("new@example.com")
        })

        XCTAssertEqual(stage, .resetFailed)
        XCTAssertEqual(resetScript.attemptCount, 1)
    }

    // Revert-check: fails if the `removeMailboxFilesLeftByStoreRecovery()` catch of
    // `prepareLocalStoreForAuthenticatedAccount` throws another stage than
    // `.recoveryFileRemovalFailed`.
    func testAccountPreparation_recoveryFileRemovalFails_throwsRecoveryFileRemovalFailed() async {
        let fixture = RecoveryResetFixture(
            markerSet: true,
            keychainEmail: "person@example.com",
            htmlCleanupFailures: 1
        )
        let session = fixture.makeSession(in: self)

        let stage = await isolationStage(thrownBy: {
            try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")
        })

        XCTAssertEqual(stage, .recoveryFileRemovalFailed)
        XCTAssertEqual(fixture.htmlCleanup.attemptCount, 1)
        XCTAssertEqual(fixture.storeReset.attemptCount, 0)
    }

    // MARK: - Launch restore over a refused preparation (account-boundary-auth#4)

    // A launch restore whose preparation could not read the reset marker changed nothing:
    // it keeps the Google session and holds the account for a later attempt. Until
    // 2026-11-27 its catch cleared the session, and the user signed in again over an
    // intact mailbox, with the sync timestamps gone.
    // Revert-check: fails if the restore callback's preparation catch clears the session
    // for every refusal (`clearFailedGoogleSession()` without asking
    // `AuthRestorePreparationPolicy`), if `restoreDisposition(after:)` maps
    // `.markerUnreadable` to `.discardCredentials`, or if the `.retryKeepingCredentials`
    // case stops setting `heldFailure`.
    func testRestore_resetMarkerUnreadableDuringPreparation_keepsCredentialsAndHoldsAccount() async {
        let restore = RestorePreparationFixture()
        let keychain = restore.keychain
        let session = makeRestoringSession(restore, beforeAnswering: {
            // The launch's own read of the marker has passed; the preparation's fails.
            keychain.failNextLoad(
                for: KeychainService.Key.localStoreResetRequired.rawValue,
                with: KeychainError.unhandledError(status: errSecInteractionNotAllowed)
            )
        })

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        assertRestoreKeptCredentialsAndHeld(session, restore)
    }

    // Revert-check: fails if `restoreDisposition(after:)` maps `.storeUninspectable` to
    // `.discardCredentials`, or if the restore callback's preparation catch clears the
    // session for every refusal.
    func testRestore_storeUninspectableDuringPreparation_keepsCredentialsAndHoldsAccount() async {
        struct InspectionFailure: Error {}
        let restore = RestorePreparationFixture()
        let session = makeRestoringSession(restore, fetchStoredAccountEmails: { throw InspectionFailure() })

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        assertRestoreKeptCredentialsAndHeld(session, restore)
    }

    // A reset that did not finish has already changed things, and its marker signs the
    // user out at the next launch by design: the restore still rejects the session.
    // Revert-check: fails if `restoreDisposition(after:)` maps `.resetFailed` to
    // `.retryKeepingCredentials`, or if the catch's `.discardCredentials` case stops
    // calling `clearFailedGoogleSession()`.
    func testRestore_storeResetFailsDuringPreparation_clearsGoogleSession() async {
        let restore = RestorePreparationFixture()
        let resetScript = AuthSessionStoreResetScript(failuresBeforeSuccess: 1)
        let session = makeRestoringSession(
            restore,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(resetScript.attemptCount, 1)
        assertRestoreClearedGoogleSession(session, restore)
    }

    // Revert-check: fails if `restoreDisposition(afterPreparationFailure:)` keeps the
    // credentials for `AuthError.missingAccountEmail`.
    func testRestore_restoredUserWithNoEmail_clearsGoogleSession() async {
        let restore = RestorePreparationFixture()
        let session = makeRestoringSession(restore, restoredEmail: nil)

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        assertRestoreClearedGoogleSession(session, restore)
    }

    // Credential persistence is never asked of the policy: once its marker may be
    // persisted, the next launch rejects the session by design.
    // Revert-check: fails if the persistence catch in the restore callback stops calling
    // `clearFailedGoogleSession()`.
    func testRestore_credentialPersistenceFails_clearsGoogleSession() async {
        struct TokenSaveFailure: Error {}
        let restore = RestorePreparationFixture()
        restore.tokenManager.saveError = TokenSaveFailure()
        let session = makeRestoringSession(restore)

        let outcome = await session.restorePreviousSignIn()

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(restore.tokenManager.saveTokensCallCount, 1)
        assertRestoreClearedGoogleSession(session, restore)
    }

    // A sign-out queued while the preparation was suspended in its reset owns the
    // teardown: the reset ends with its `CancellationError`, wrapped as `.resetFailed`,
    // and the restore must clear nothing itself.
    // Revert-check: fails if the restore callback's preparation catch stops asking
    // `isAccountRemovalRequested` before the policy (the policy's `.resetFailed` then calls
    // `clearFailedGoogleSession()`, a second Google sign-out racing the sign-out's own).
    func testRestore_signOutQueuedDuringPreparation_leavesTheTeardownToTheSignOut() async {
        let restore = RestorePreparationFixture()
        let resetGate = AuthSessionStoreResetGate()
        let session = makeRestoringSession(
            restore,
            resetCoreDataStore: { await resetGate.reset() },
            fetchStoredAccountEmails: { ["old@example.com"] }
        )

        let restoreTask = Task { @MainActor in await session.restorePreviousSignIn() }
        await resetGate.waitUntilFirstResetStarted()
        let saveCountBeforeSignOut = restore.keychain.saveCallCount
        let signOutTask = Task { @MainActor in await session.signOut() }
        // `signOut()` writes its marker and registers its request before its first
        // suspension, so the save is the registration's witness.
        await waitUntil { restore.keychain.saveCallCount > saveCountBeforeSignOut }
        await resetGate.releaseFirstReset()

        let outcome = await restoreTask.value
        let didSignOut = await signOutTask.value

        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertTrue(didSignOut)
        XCTAssertEqual(
            restore.events.events.filter { $0 == "google-sign-out" },
            ["google-sign-out"],
            "Only the sign-out signs Google out"
        )
        XCTAssertNil(session.heldAccount)
        XCTAssertFalse(session.isAuthenticated)
    }

    // The restore's preparation catch asks whether a sign-out is queued before anything
    // else, and only then the policy; and the policy is asked nowhere else, so interactive
    // sign-in stays all-or-none. Comment lines are skipped.
    // HONEST SCOPE: this reads source text. The runtime halves are the restore tests
    // above; interactive sign-in's preparation refusals are not run, because a
    // `GIDSignInResult` cannot be made (its `init` is unavailable).
    // Revert-check: fails if the catch's `isAccountRemovalRequested` guard is dropped or
    // moved after the policy's switch, if the preparation shares its do block with the
    // credential persistence again, or if another call of
    // `AuthRestorePreparationPolicy.restoreDisposition` is added to the app.
    func testRestorePreparationCatch_asksForQueuedSignOutThenThePolicy() throws {
        let code = try codeLinesWithoutComments("esc-chatmail/Services/Security/AuthSession.swift")
        let preparation = try XCTUnwrap(code.firstIndex(
            of: "try await self.prepareLocalStoreForAuthenticatedAccount(user.profile?.email)"
        ))
        XCTAssertEqual(code[preparation + 1], "} catch {", "The preparation is alone in its do block")
        let catchStart = preparation + 1
        let removalGuard = try XCTUnwrap(code[catchStart...].firstIndex(
            of: "guard !self.isAccountRemovalRequested else {"
        ))
        let policy = try XCTUnwrap(code[catchStart...].firstIndex {
            $0.contains("AuthRestorePreparationPolicy.restoreDisposition(afterPreparationFailure: error)")
        })
        let firstClear = try XCTUnwrap(code[catchStart...].firstIndex {
            $0.contains("self.clearFailedGoogleSession()")
        })
        XCTAssertLessThan(removalGuard, policy)
        XCTAssertLessThan(policy, firstClear)
        XCTAssertEqual(
            Array(code[(removalGuard + 1)...(removalGuard + 3)]),
            ["restoredUser.restoreOutcome = .retryableFailure", "return", "}"],
            "A queued sign-out returns with nothing cleared"
        )

        var callers: [String] = []
        for path in try repositorySwiftFilePaths(under: "esc-chatmail")
        where !path.hasSuffix("/AuthRestorePreparationPolicy.swift") {
            let calls = try codeLinesWithoutComments(path)
                .filter { $0.contains("AuthRestorePreparationPolicy.restoreDisposition") }
                .count
            if calls > 0 {
                callers.append("\(path) \(calls)")
            }
        }
        XCTAssertEqual(callers, ["esc-chatmail/Services/Security/AuthSession.swift 1"])
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

    // A sign-in over another account's store resets it through `performDurableLocalCleanup`,
    // and the alias caches, built from the Account row the reset removes, are dropped
    // there: after the reset and before account work reopens. Until 2026-11-27 only the
    // four removal paths dropped them (inline), so a sign-in from the reconnect screen as
    // another account kept the old account's addresses as the new one's own until the
    // first sync's profile fetch (architecture review 2026-11, account-boundary-auth#2).
    // Revert-check: fails if the `invalidateAccountAliasCaches()` call in
    // `performDurableLocalCleanup` goes (no event), or moves ahead of `resetCoreDataStore()`
    // (the order changes: before the reset an unfenced reader can refill the old row's
    // addresses).
    func testAccountPreparationInvalidatesAliasCachesAfterTheStoreResetBeforeReopening() async throws {
        let cleanup = AuthSessionCleanupRecorder()
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let transition = registry.closeAdmission()
        let session = makeAuthSession(
            clearParticipantCaches: { cleanup.record("participant-caches-cleared") },
            invalidateAccountAliasCaches: { cleanup.record("alias-caches-invalidated") },
            resetCoreDataStore: { cleanup.record("store-reset") },
            fetchStoredAccountEmails: { ["first@example.com"] },
            reopenHTMLContent: { cleanup.record("html-reopened") },
            outboundTaskRegistry: registry
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("SECOND@example.com")
        let reopenOutcome = await session.reopenAccountWork(after: transition)

        XCTAssertEqual(reopenOutcome, .reopened)
        XCTAssertEqual(
            cleanup.events,
            ["participant-caches-cleared", "store-reset", "alias-caches-invalidated", "html-reopened"]
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

    // A sign-out over real directories, with the app's own file cleanup wired to them and the
    // background removal held: what a sign-out awaits, and what the sign-in after it finds
    // while the last account's files are still on disk.
    //
    // Revert-check, two of them.
    // 1. `RetiredAccountDirectory.takeOutOfUse` in `AuthSession.retireAttachmentDirectories`
    //    and in `HTMLContentHandler`'s cleanup. Unlink the files there, as before, and
    //    nothing is left for the held removal: the count of files still on disk is 0.
    // 2. The tombstone policy of `AccountScopedMailboxFileInspector.hasStoredFiles` and
    //    `HTMLContentHandler.hasStoredHTMLFiles`. Count a tombstone as account data and
    //    the account preparation resets the store a second time.
    // 3. `HTMLContentAccountBoundary.inspect` behind `hasStoredHTMLFiles`, which answers
    //    while the boundary is closed. Answer `true` for a closed boundary instead (the
    //    `perform(…) ?? true` of before) and the preparation, which the app runs before
    //    the reopen, resets the store a second time (architecture review 2026-11,
    //    account-boundary-auth#3). Until 2026-11-27 this test reopened the handler
    //    before preparing, so it never took the app's path.
    // HONEST SCOPE: the cleanup closures here are built from the functions `AuthSession`'s
    // defaults call, over temporary directories, because the defaults themselves act on
    // the process's shared stores. That the defaults call them is not run by any test.
    func testSignOut_overRealFiles_returnsWithEveryFileStillOnDisk_andTheNextSignInFindsAnEmptyMailbox() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AuthSessionRetiredFiles-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let messages = root.appendingPathComponent("Documents/Messages", isDirectory: true)
        let held = AuthSessionHeldTombstones()
        defer {
            held.urls.forEach { RetiredAccountDirectory.remove($0) }
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        for name in ["Attachments", "Previews"] {
            let directory = appSupport.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<3 {
                try Data("old".utf8).write(to: directory.appendingPathComponent("file-\(index).bin"))
            }
        }
        let handler = HTMLContentHandler(
            messagesDirectory: messages,
            deleteHTMLFiles: { directory in
                held.add(try RetiredAccountDirectory.takeOutOfUse(directory))
            }
        )
        for index in 0..<3 {
            XCTAssertNotNil(handler.saveHTML("<p>old account</p>", for: "message-\(index)"))
        }
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] },
            hasStoredAccountScopedMailboxData: {
                try handler.hasStoredHTMLFiles() || AccountScopedMailboxFileInspector.hasStoredFiles(
                    appSupportDirectory: appSupport,
                    cachesDirectory: caches
                )
            },
            deleteAttachmentFiles: {
                try AuthSession.retireAttachmentDirectories(
                    appSupportDirectory: appSupport,
                    cachesDirectory: caches,
                    removeTombstone: { held.add($0) }
                )
            },
            cleanupHTMLContent: {
                handler.closeAccountWork()
                try await handler.deleteAllHTMLFromClosedAccount()
            },
            reopenHTMLContent: { try handler.reopenAccountWork() }
        )

        let didSignOut = await session.signOut()

        XCTAssertTrue(didSignOut)
        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertEqual(held.urls.count, 3, "Messages, Attachments and Previews each became one tombstone")
        let filesStillOnDisk = try held.urls.reduce(0) { count, tombstone in
            count + (try fileManager.contentsOfDirectory(atPath: tombstone.path).count)
        }
        XCTAssertEqual(filesStillOnDisk, 9, "The sign-out returned without unlinking a file")
        XCTAssertFalse(fileManager.fileExists(atPath: messages.path))
        XCTAssertFalse(fileManager.fileExists(atPath: appSupport.appendingPathComponent("Attachments").path))
        XCTAssertFalse(fileManager.fileExists(atPath: appSupport.appendingPathComponent("Previews").path))

        // The next sign-in, with the removal still not done, in the app's order: the
        // preparation runs with the handler still closed (`signIn` reopens account work
        // only after `prepareLocalStoreForAuthenticatedAccount` returns), and the reopen
        // then makes the Messages directory again.
        try await session.prepareLocalStoreForAuthenticatedAccount(
            "next@example.com",
            entry: .interactiveSignIn
        )

        XCTAssertEqual(
            resetScript.attemptCount,
            1,
            "Tombstones are not another account's mailbox: the sign-in must not reset the store again"
        )
        try handler.reopenAccountWork()
        XCTAssertNil(handler.loadHTML(for: "message-0"))
        XCTAssertNotNil(handler.saveHTML("<p>next account</p>", for: "message-0"))
        XCTAssertEqual(handler.loadHTML(for: "message-0"), "<p>next account</p>")
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

    // MARK: - Mail-derived caches

    // Revert-check: fails if `AuthSession.clearWebViewData` awaits
    // `removeAllWebViewData()` directly, in place of through
    // `withSoftTimeout`, or if WebKit's removal is called from anywhere else.
    // The durable cleanup awaits that removal with the auth-transition gate
    // held and its reset marker still to hand over, and nothing bounds
    // WebKit's answer: one that never came would leave the sign-out
    // unfinished and every later sign-in waiting on the gate.
    // HONEST SCOPE: this reads source text. No test asks WebKit to remove
    // anything or makes it stall; `AsyncTimeoutTests` pins that
    // `withSoftTimeout` returns at its bound over work that has not finished.
    func testClearWebViewData_webKitRemoval_isAwaitedThroughASoftTimeout() throws {
        let code = try repositorySource("esc-chatmail/Services/Security/AuthSession.swift")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }

        let boundedWait = try XCTUnwrap(code.firstIndex(
            of: "let finished = await withSoftTimeout(seconds: webViewDataRemovalTimeout) {"
        ))
        XCTAssertEqual(code[boundedWait - 1], "private static func clearWebViewData() async {")
        XCTAssertEqual(code[boundedWait + 1], "await removeAllWebViewData()")
        XCTAssertEqual(
            code.filter { $0.contains("removeAllWebViewData()") },
            ["await removeAllWebViewData()", "private static func removeAllWebViewData() async {"],
            "WebKit's removal must be awaited only inside the bounded wait"
        )

        let removal = try XCTUnwrap(code.firstIndex(of: "private static func removeAllWebViewData() async {"))
        XCTAssertEqual(code[removal + 1], "await WKWebsiteDataStore.default().removeData(")
        XCTAssertEqual(
            code.filter { $0.contains("WKWebsiteDataStore") }.count,
            2,
            "The web views' data store must be touched only in removeAllWebViewData()"
        )
    }

    // MARK: - Mailbox start time

    // Revert-check: fails if `performDurableLocalCleanup` stops calling
    // `restartMailboxStartTime()`. With the old start left in place, the next
    // sign-in's initial sync listed up to 30 days of the mail the sign-out
    // had just removed.
    func testSignOut_wipedMailbox_restartsMailboxStartTime() async {
        let defaults = makeDefaults()
        let oldStart = Date().timeIntervalSince1970 - 400 * 86_400
        defaults.set(oldStart, forKey: SyncConfig.mailboxStartTimestampKey)
        let session = makeAuthSession(userDefaults: defaults)
        let signOutTime = Date().timeIntervalSince1970

        await session.signOut()

        XCTAssertGreaterThanOrEqual(
            defaults.double(forKey: SyncConfig.mailboxStartTimestampKey),
            signOutTime,
            "A wiped mailbox must not keep the start of the one that was removed"
        )
        XCTAssertGreaterThanOrEqual(
            SyncTimeCalculator.calculateStartTime(config: .initialSync, defaults: defaults),
            signOutTime - SyncConfig.timestampBufferSeconds,
            "The next initial sync must list nothing from before the sign-out"
        )
    }

    // Revert-check: fails if `prepareLocalStoreForAuthenticatedAccount` stops
    // calling `restartMailboxStartTime()` for an interactive sign-in that finds
    // the store empty. The start then stays at the sign-out (or at the first
    // launch of a new install), and the mail that arrived while signed out is
    // brought in.
    func testAccountPreparation_interactiveSignInFindsEmptyStore_restartsMailboxStartTime() async throws {
        let defaults = makeDefaults()
        let signedOutAt = Date().timeIntervalSince1970 - 3 * 86_400
        defaults.set(signedOutAt, forKey: SyncConfig.mailboxStartTimestampKey)
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { [] }
        )
        let signInTime = Date().timeIntervalSince1970

        try await session.prepareLocalStoreForAuthenticatedAccount(
            "person@example.com",
            entry: .interactiveSignIn
        )

        XCTAssertEqual(resetScript.attemptCount, 0, "An empty store needs no reset")
        XCTAssertGreaterThanOrEqual(
            defaults.double(forKey: SyncConfig.mailboxStartTimestampKey),
            signInTime,
            "A sign-in onto an empty store starts the mailbox at the sign-in"
        )
        XCTAssertGreaterThanOrEqual(
            SyncTimeCalculator.calculateStartTime(config: .initialSync, defaults: defaults),
            signInTime - SyncConfig.timestampBufferSeconds,
            "The initial sync must list nothing from the days signed out"
        )
    }

    // Revert-check: fails if the `entry == .interactiveSignIn` condition is
    // dropped from `prepareLocalStoreForAuthenticatedAccount`. A launch after
    // a sign-in whose first sync saved nothing finds the store empty too, and
    // moving the start there skips the mail since that sign-in.
    func testAccountPreparation_restoredSessionFindsEmptyStore_keepsMailboxStartTime() async throws {
        let defaults = makeDefaults()
        let signedInAt = Date().timeIntervalSince1970 - 86_400
        defaults.set(signedInAt, forKey: SyncConfig.mailboxStartTimestampKey)
        let session = makeAuthSession(
            userDefaults: defaults,
            fetchStoredAccountEmails: { [] }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")

        XCTAssertEqual(defaults.double(forKey: SyncConfig.mailboxStartTimestampKey), signedInAt)
    }

    // Revert-check: fails if `prepareLocalStoreForAuthenticatedAccount` moves
    // the start without `foundEmptyStore`. Over a retained mailbox a moved
    // start is the floor of history recovery, which would then skip the mail
    // between the old start and the sign-in.
    func testAccountPreparation_interactiveSignInKeepsMatchingStore_keepsMailboxStartTime() async throws {
        let defaults = makeDefaults()
        let mailboxStart = Date().timeIntervalSince1970 - 90 * 86_400
        defaults.set(mailboxStart, forKey: SyncConfig.mailboxStartTimestampKey)
        let session = makeAuthSession(
            userDefaults: defaults,
            fetchStoredAccountEmails: { ["person@example.com"] }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount(
            "person@example.com",
            entry: .interactiveSignIn
        )

        XCTAssertEqual(defaults.double(forKey: SyncConfig.mailboxStartTimestampKey), mailboxStart)
    }

    // Revert-check: fails if `performDurableLocalCleanup` stops calling
    // `restartMailboxStartTime()`. A restored session takes this path too, so
    // the reset itself has to move the start: the entry does not.
    func testAccountPreparation_restoredSessionReplacesForeignStore_restartsMailboxStartTime() async throws {
        let defaults = makeDefaults()
        defaults.set(Date().timeIntervalSince1970 - 90 * 86_400, forKey: SyncConfig.mailboxStartTimestampKey)
        let resetScript = AuthSessionStoreResetScript()
        let session = makeAuthSession(
            userDefaults: defaults,
            resetCoreDataStore: { try resetScript.reset() },
            fetchStoredAccountEmails: { ["first@example.com"] }
        )
        let resetTime = Date().timeIntervalSince1970

        try await session.prepareLocalStoreForAuthenticatedAccount("second@example.com")

        XCTAssertEqual(resetScript.attemptCount, 1)
        XCTAssertGreaterThanOrEqual(
            defaults.double(forKey: SyncConfig.mailboxStartTimestampKey),
            resetTime
        )
    }

    // MARK: - A store reset by recovery, not by a sign-out

    // Revert-check: the `isStoreRecoveryOfAccount` branch of
    // `prepareLocalStoreForAuthenticatedAccount` (setting `resetRequired` there runs the
    // full cleanup: a second store reset, which removes every backup, and a mailbox start
    // moved to now, so about five minutes of mail came back), and the
    // `StoreRecoveryResetMarker.clear` in `removeMailboxFilesLeftByStoreRecovery`.
    func testAccountPreparation_restoreAfterRecoveryResetOfSameAccount_removesFilesOnlyAndKeepsStart() async throws {
        let fixture = RecoveryResetFixture(markerSet: true, keychainEmail: "person@example.com")
        let session = fixture.makeSession(in: self)

        try await session.prepareLocalStoreForAuthenticatedAccount("Person@Example.com")

        XCTAssertEqual(fixture.htmlCleanup.attemptCount, 1, "The orphaned bodies go before anything is published")
        XCTAssertEqual(fixture.fileCleanup.attemptCount, 1, "The orphaned attachments go too")
        XCTAssertEqual(fixture.storeReset.attemptCount, 0, "A second reset would remove the reset's own backup")
        XCTAssertEqual(
            fixture.defaults.double(forKey: SyncConfig.mailboxStartTimestampKey),
            fixture.mailboxStart,
            "A store reset with no sign-out moves nothing"
        )
        XCTAssertFalse(StoreRecoveryResetMarker.isMarked(in: fixture.defaults))
        XCTAssertFalse(fixture.defaults.bool(forKey: AuthSession.localStoreResetRequiredKey))
        XCTAssertEqual(
            try fixture.keychain.loadString(for: KeychainService.Key.googleUserEmail.rawValue),
            "person@example.com",
            "The account's credentials are not part of the cleanup"
        )
    }

    // Revert-check: the `StoreRecoveryResetMarker.isMarked` condition of
    // `AuthSession.isStoreRecoveryOfAccount`. Without it any empty store beside files
    // whose keychain names the account skips the store reset.
    func testAccountPreparation_filesBesideEmptyStoreWithNoMarker_runsFullCleanup() async throws {
        let fixture = RecoveryResetFixture(markerSet: false, keychainEmail: "person@example.com")
        let session = fixture.makeSession(in: self)
        let cleanupTime = Date().timeIntervalSince1970

        try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")

        XCTAssertEqual(fixture.storeReset.attemptCount, 1)
        XCTAssertGreaterThanOrEqual(fixture.defaults.double(forKey: SyncConfig.mailboxStartTimestampKey), cleanupTime)
    }

    // Revert-check: the email comparison in `AuthSession.isStoreRecoveryOfAccount`.
    // Without it a reset store's files are kept from another account's cleanup.
    func testAccountPreparation_recoveryMarkerButAnotherAccount_runsFullCleanupAndClearsMarker() async throws {
        let fixture = RecoveryResetFixture(markerSet: true, keychainEmail: "first@example.com")
        let session = fixture.makeSession(in: self)

        try await session.prepareLocalStoreForAuthenticatedAccount("second@example.com")

        XCTAssertEqual(fixture.storeReset.attemptCount, 1)
        XCTAssertFalse(StoreRecoveryResetMarker.isMarked(in: fixture.defaults), "The full cleanup consumes the marker")
    }

    // Revert-check: the order of the `hasAccountScopedRows` check ahead of
    // `hasAccountScopedFiles` in `prepareLocalStoreForAuthenticatedAccount`. Rows with no
    // Account row are never proof of anything, marker or not.
    func testAccountPreparation_recoveryMarkerButRowsRemain_runsFullCleanup() async throws {
        let fixture = RecoveryResetFixture(markerSet: true, keychainEmail: "person@example.com", hasRows: true)
        let session = fixture.makeSession(in: self)

        try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")

        XCTAssertEqual(fixture.storeReset.attemptCount, 1)
    }

    // Revert-check: `AuthSession.isStoreRecoveryOfAccount` taking an unreadable keychain
    // for the account being prepared. A keychain that cannot be read is not proof that the
    // files are this account's, so they get the full cleanup, as before the exception.
    // (Throwing instead was ruled out when every refused preparation cleared the failed
    // Google session; a nothing-changed stage now keeps it, and whether this read should be
    // one is open: see `AuthSession.isStoreRecoveryOfAccount`.)
    func testAccountPreparation_recoveryMarkerButKeychainUnreadable_runsFullCleanup() async throws {
        let fixture = RecoveryResetFixture(markerSet: true, keychainEmail: "person@example.com")
        let session = fixture.makeSession(
            in: self,
            keychainService: EmailReadFailingKeychain(wrapping: fixture.keychain)
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")

        XCTAssertEqual(fixture.storeReset.attemptCount, 1)
        XCTAssertFalse(StoreRecoveryResetMarker.isMarked(in: fixture.defaults))
    }

    // Revert-check: the `StoreRecoveryResetMarker.clear` in the no-reset path of
    // `prepareLocalStoreForAuthenticatedAccount`. A marker left by a reset whose store then
    // refilled would otherwise wait for a later, unrelated empty store.
    func testAccountPreparation_matchingAccountRow_clearsStaleRecoveryMarker() async throws {
        let defaults = makeDefaults()
        StoreRecoveryResetMarker.mark(in: defaults)
        let session = makeAuthSession(
            userDefaults: defaults,
            fetchStoredAccountEmails: { ["person@example.com"] }
        )

        try await session.prepareLocalStoreForAuthenticatedAccount("person@example.com")

        XCTAssertFalse(StoreRecoveryResetMarker.isMarked(in: defaults))
    }

    // Revert-check: fails if `clearAccountScopedSyncDefaults()` stops removing
    // `SyncConfig.missedMessageReconciliationCursorKey`. The cursor holds the
    // old window's `after:` query and is valid for a day, so the next
    // sign-in's first reconciliation resumed it and fetched that window's
    // mail as missing.
    func testSignOut_pendingMissedMessageCursor_isRemoved() async {
        let defaults = makeDefaults()
        defaults.set(Data("cursor".utf8), forKey: SyncConfig.missedMessageReconciliationCursorKey)
        let session = makeAuthSession(userDefaults: defaults)

        await session.signOut()

        XCTAssertNil(
            defaults.object(forKey: SyncConfig.missedMessageReconciliationCursorKey),
            "A sign-out must not leave a window of the old mailbox for the next sign-in to resume"
        )
    }

    // Revert-check: fails if `clearAccountScopedSyncDefaults()` stops calling
    // `SendAsAliasRefreshPolicy.forgetAllAccounts(in:)`. The key is named
    // after the account's address, which then stays in the preferences.
    func testSignOut_sendAsAliasRefreshTimestamp_isRemovedWithItsAddress() async {
        let defaults = makeDefaults()
        SendAsAliasRefreshPolicy(userDefaults: defaults)
            .recordSuccessfulRefresh(accountEmail: "Person@Example.com")
        XCTAssertTrue(
            defaults.dictionaryRepresentation().keys.contains { $0.contains("person@example.com") },
            "Precondition: the refresh timestamp's key names the account"
        )
        let session = makeAuthSession(userDefaults: defaults)

        await session.signOut()

        XCTAssertFalse(
            defaults.dictionaryRepresentation().keys.contains { $0.contains("person@example.com") },
            "A sign-out must not leave the account's address in the preferences"
        )
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
        let legacyContinuation = #"{"mode":"history","startHistoryId":"old-history","pageToken":"old-page","accountEmail":"old@example.com"}"#
        defaults.set(Data(legacyContinuation.utf8), forKey: "backgroundSync.continuationState")
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
        XCTAssertNil(defaults.object(forKey: "backgroundSync.continuationState"))
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

    // Revert-check: fails if AuthSession.reopenAccountWork(after:) maps
    // OutboundAdmissionReopenResult.undrainedSends back to
    // .supersededByAccountRemoval (the conflation this split removed) or stops
    // rolling back the already-reopened subsystems. No queued sign-out exists
    // in this state, so a supersession verdict would tell the restore path
    // that another transition owns the staged credentials when nothing does.
    //
    // HONEST SCOPE: the undrained reservation is manufactured by reserving
    // before closeAdmission() and never finishing. AuthSession's own
    // transition paths cannot reach this state today, because every one of
    // them runs cancelAndAwaitAll() — which waits for the entry table to
    // drain — before any reopen. This pins the contract against a future
    // leak, not a reachable regression.
    func testUndrainedOutboundSendReportsLatchedRefusalAndRollsBack() async throws {
        let registry = OutboundTaskRegistry(admissionOpen: true)
        let leakedReservation = try XCTUnwrap(registry.reserve())
        let transition = registry.closeAdmission()
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

        let reopenOutcome = await session.reopenAccountWork(after: transition)

        XCTAssertEqual(
            reopenOutcome,
            .latchedRefusal,
            "An undrained send has no superseding sign-out to own it; reporting supersession would be false"
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
        // Bind-and-finish the probe so a failing run doesn't leak an entry
        // that would cascade the reopen assertion below into a second,
        // misleading failure.
        let admissionProbe = registry.reserve()
        XCTAssertNil(
            admissionProbe,
            "An undrained send must leave every account-scoped admission closed"
        )
        if let admissionProbe {
            registry.finish(admissionProbe)
        }

        // The latch is the leaked reservation, not the generation: draining it
        // lets this same transition reopen outbound admission.
        registry.finish(leakedReservation)
        XCTAssertEqual(registry.reopenAdmission(after: transition), .reopened)
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
            try await session.signIn(presenting: makePresentationAnchor())
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
            try await session.signIn(presenting: makePresentationAnchor())
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
            try await session.signIn(presenting: makePresentationAnchor())
        }
        await interactiveSignIn.waitUntilFirstStarted()

        let firstRemovalTask = Task { @MainActor in
            await session.signOut()
        }
        await session.waitUntilAuthenticationTransitionWaiterCountForTesting(1)

        let interveningSignInTask = Task { @MainActor in
            try await session.signIn(presenting: makePresentationAnchor())
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

    /// A throwaway anchor for `signIn(presenting:)`: a view controller on iOS, a window on the
    /// Mac (`PresentationAnchor`). Every test injects `interactiveGoogleSignIn`, so nothing is
    /// ever presented from it.
    private func makePresentationAnchor() -> PresentationAnchor {
        #if os(iOS)
        UIViewController()
        #elseif os(macOS)
        NSWindow()
        #endif
    }

    private func makeAuthSession(
        tokenManagerProvider: @escaping @MainActor @Sendable () -> TokenManagerProtocol = { MockTokenManager() },
        keychainService: KeychainServiceProtocol = MockKeychainService(),
        hasPreviousGoogleSignIn: @escaping @MainActor @Sendable () -> Bool = { false },
        googleSignInKeychainPresence: @escaping @Sendable () -> GoogleSignInKeychainPresence = { .absent },
        restorePreviousGoogleSignIn: @escaping @MainActor @Sendable (
            @escaping (GIDGoogleUser?, Error?) -> Void
        ) -> Void = { _ in },
        interactiveGoogleSignIn: @escaping @MainActor @Sendable (
            PresentationAnchor,
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
        resetSyncStorageState: @escaping @MainActor @Sendable () -> Void = {},
        invalidateAccountAliasCaches: @escaping @Sendable () async -> Void = {},
        cancelBackgroundTaskRequests: @escaping @MainActor @Sendable () -> Void = {},
        resetCoreDataStore: @escaping @Sendable () async throws -> Void = {},
        fetchStoredAccountEmails: @escaping @Sendable () async throws -> [String] = { [] },
        hasStoredAccountScopedMailboxData: @escaping @Sendable () async throws -> Bool = { false },
        hasStoredAccountScopedFiles: @escaping @Sendable () async throws -> Bool = { false },
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
            googleSignInKeychainPresence: googleSignInKeychainPresence,
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
            resetSyncStorageState: resetSyncStorageState,
            invalidateAccountAliasCaches: invalidateAccountAliasCaches,
            cancelBackgroundTaskRequests: cancelBackgroundTaskRequests,
            resetCoreDataStore: resetCoreDataStore,
            inspectLocalMailboxStore: {
                LocalMailboxStoreInspection(
                    accountEmails: try await fetchStoredAccountEmails(),
                    hasAccountScopedRows: try await hasStoredAccountScopedMailboxData(),
                    hasAccountScopedFiles: try await hasStoredAccountScopedFiles()
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

    /// `makeAuthSession` for `RecoveryResetFixture`, which is outside this class.
    fileprivate func makeRecoveryResetSession(
        keychainService: KeychainServiceProtocol,
        userDefaults: UserDefaults,
        resetCoreDataStore: @escaping @Sendable () async throws -> Void,
        hasStoredAccountScopedMailboxData: @escaping @Sendable () async throws -> Bool,
        hasStoredAccountScopedFiles: @escaping @Sendable () async throws -> Bool,
        deleteAttachmentFiles: @escaping @Sendable () async throws -> Void,
        cleanupHTMLContent: @escaping @MainActor @Sendable () async throws -> Void
    ) -> AuthSession {
        makeAuthSession(
            keychainService: keychainService,
            userDefaults: userDefaults,
            resetCoreDataStore: resetCoreDataStore,
            fetchStoredAccountEmails: { [] },
            hasStoredAccountScopedMailboxData: hasStoredAccountScopedMailboxData,
            hasStoredAccountScopedFiles: hasStoredAccountScopedFiles,
            deleteAttachmentFiles: deleteAttachmentFiles,
            cleanupHTMLContent: cleanupHTMLContent
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AuthSessionTests.\(UUID().uuidString)")!
    }

    /// The stage `body` threw `AuthError.localAccountIsolationFailed` with; nil, and a
    /// failure, for any other ending.
    private func isolationStage(
        thrownBy body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> LocalAccountIsolationStage? {
        do {
            try await body()
            XCTFail("Expected the account preparation to refuse", file: file, line: line)
            return nil
        } catch {
            guard let stage = (error as? AuthError)?.localAccountIsolationStage else {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
                return nil
            }
            return stage
        }
    }

    /// A launch restore over `restore`'s earlier launch, whose SDK restore answers with a
    /// `StubGoogleUser` for `restoredEmail`. `beforeAnswering` runs first, after the
    /// launch's own reads of the markers.
    private func makeRestoringSession(
        _ restore: RestorePreparationFixture,
        restoredEmail: String? = RestorePreparationFixture.accountEmail,
        beforeAnswering: @escaping @MainActor @Sendable () -> Void = {},
        resetCoreDataStore: @escaping @Sendable () async throws -> Void = {},
        fetchStoredAccountEmails: @escaping @Sendable () async throws -> [String] = {
            [RestorePreparationFixture.accountEmail]
        }
    ) -> AuthSession {
        let tokenManager = restore.tokenManager
        let events = restore.events
        return makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: restore.keychain,
            hasPreviousGoogleSignIn: { true },
            googleSignInKeychainPresence: { .present },
            restorePreviousGoogleSignIn: { completion in
                beforeAnswering()
                completion(StubGoogleUser(email: restoredEmail), nil)
            },
            signOutGoogleSession: { events.record("google-sign-out") },
            userDefaults: restore.defaults,
            resetCoreDataStore: resetCoreDataStore,
            fetchStoredAccountEmails: fetchStoredAccountEmails
        )
    }

    /// The restore kept everything of the earlier launch and held the account.
    private func assertRestoreKeptCredentialsAndHeld(
        _ session: AuthSession,
        _ restore: RestorePreparationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(restore.events.events, [], "The SDK session stays", file: file, line: line)
        XCTAssertEqual(restore.tokenManager.clearTokensCallCount, 0, file: file, line: line)
        XCTAssertEqual(
            restore.tokenManager.saveTokensCallCount,
            0,
            "Nothing of the restored session is persisted before its mailbox is checked",
            file: file,
            line: line
        )
        XCTAssertEqual(
            restore.keychain.saveCallCount,
            0,
            "No keychain write: no cleanup marker, no signed-out verdict",
            file: file,
            line: line
        )
        XCTAssertEqual(restore.keychain.deleteCallCount, 0, file: file, line: line)
        XCTAssertTrue(
            restore.keychain.exists(for: KeychainService.Key.googleUserEmail.rawValue),
            file: file,
            line: line
        )
        XCTAssertEqual(
            restore.defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey),
            restore.lastSuccessfulSyncTime,
            "The sync timestamps stay",
            file: file,
            line: line
        )
        XCTAssertFalse(session.isAuthenticated, file: file, line: line)
        XCTAssertFalse(session.isDurablySignedOut(), file: file, line: line)
        XCTAssertEqual(
            session.heldAccount,
            HeldAccount(email: RestorePreparationFixture.accountEmail, failure: .couldNotRestore),
            file: file,
            line: line
        )
    }

    /// The restore rejected the session through `clearFailedGoogleSession()`.
    private func assertRestoreClearedGoogleSession(
        _ session: AuthSession,
        _ restore: RestorePreparationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(restore.events.events, ["google-sign-out"], file: file, line: line)
        XCTAssertGreaterThanOrEqual(restore.tokenManager.clearTokensCallCount, 1, file: file, line: line)
        XCTAssertTrue(
            restore.keychain.exists(for: KeychainService.Key.durableSignedOut.rawValue),
            "The signed-out verdict is persisted",
            file: file,
            line: line
        )
        XCTAssertNil(session.heldAccount, file: file, line: line)
        XCTAssertFalse(session.isAuthenticated, file: file, line: line)
    }

    private func codeLinesWithoutComments(_ path: String) throws -> [String] {
        try repositorySource(path)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }
}

/// A launch restore's earlier launch: the app's keychain names the account, the sync
/// timestamps are set, and the SDK holds a session for the same account.
private final class RestorePreparationFixture {
    static let accountEmail = "person@example.com"

    let keychain = MockKeychainService()
    let tokenManager = MockTokenManager()
    let defaults = UserDefaults(suiteName: "AuthSessionTests.restorePreparation.\(UUID().uuidString)")!
    let events = AuthSessionCleanupRecorder()
    let lastSuccessfulSyncTime = Date().timeIntervalSince1970 - 600

    init() {
        keychain.preloadStrings([KeychainService.Key.googleUserEmail.rawValue: Self.accountEmail])
        defaults.set(lastSuccessfulSyncTime, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
    }
}

private final class AuthSessionHeldTombstones: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ url: URL?) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        stored.append(url)
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

/// A restore that finds an empty store beside stored files, with or without the marker a
/// recovery reset leaves, and the keychain naming the previous session's account.
@MainActor
private final class RecoveryResetFixture {
    let defaults = UserDefaults(suiteName: "AuthSessionTests.recovery.\(UUID().uuidString)")!
    let keychain = MockKeychainService()
    let storeReset = AuthSessionStoreResetScript()
    let fileCleanup = AuthSessionFileCleanupScript(failuresBeforeSuccess: 0)
    let htmlCleanup: AuthSessionHTMLCleanupScript
    let mailboxStart = Date().timeIntervalSince1970 - 90 * 86_400
    private let hasRows: Bool

    init(markerSet: Bool, keychainEmail: String, hasRows: Bool = false, htmlCleanupFailures: Int = 0) {
        self.hasRows = hasRows
        htmlCleanup = AuthSessionHTMLCleanupScript(failuresBeforeSuccess: htmlCleanupFailures)
        defaults.set(mailboxStart, forKey: SyncConfig.mailboxStartTimestampKey)
        if markerSet {
            StoreRecoveryResetMarker.mark(in: defaults)
        }
        keychain.preloadStrings([KeychainService.Key.googleUserEmail.rawValue: keychainEmail])
    }

    func makeSession(in tests: AuthSessionTests, keychainService: KeychainServiceProtocol? = nil) -> AuthSession {
        let storeReset = self.storeReset
        let fileCleanup = self.fileCleanup
        let htmlCleanup = self.htmlCleanup
        let hasRows = self.hasRows
        return tests.makeRecoveryResetSession(
            keychainService: keychainService ?? keychain,
            userDefaults: defaults,
            resetCoreDataStore: { try storeReset.reset() },
            hasStoredAccountScopedMailboxData: { hasRows },
            hasStoredAccountScopedFiles: { true },
            deleteAttachmentFiles: { try fileCleanup.deleteFiles() },
            cleanupHTMLContent: { try htmlCleanup.cleanup() }
        )
    }
}

/// `MockKeychainService`, except that the account's email cannot be read.
private final class EmailReadFailingKeychain: KeychainServiceProtocol {
    private struct ReadFailure: Error {}
    private let base: MockKeychainService

    init(wrapping base: MockKeychainService) {
        self.base = base
    }

    func save(_ data: Data, for key: String, withAccess access: KeychainService.AccessLevel) throws {
        try base.save(data, for: key, withAccess: access)
    }

    func load(for key: String) throws -> Data {
        if key == KeychainService.Key.googleUserEmail.rawValue { throw ReadFailure() }
        return try base.load(for: key)
    }

    func delete(for key: String) throws {
        try base.delete(for: key)
    }

    func exists(for key: String) -> Bool {
        base.exists(for: key)
    }

    func update(_ data: Data, for key: String, withAccess access: KeychainService.AccessLevel?) throws {
        try base.update(data, for: key, withAccess: access)
    }

    func clearAll() throws {
        try base.clearAll()
    }

    func saveString(_ string: String, for key: String, withAccess access: KeychainService.AccessLevel) throws {
        try base.saveString(string, for: key, withAccess: access)
    }

    func loadString(for key: String) throws -> String {
        if key == KeychainService.Key.googleUserEmail.rawValue { throw ReadFailure() }
        return try base.loadString(for: key)
    }

    func saveCodable<T: Codable>(_ object: T, for key: String, withAccess access: KeychainService.AccessLevel) throws {
        try base.saveCodable(object, for: key, withAccess: access)
    }

    func loadCodable<T: Codable>(_ type: T.Type, for key: String) throws -> T {
        try base.loadCodable(type, for: key)
    }
}
