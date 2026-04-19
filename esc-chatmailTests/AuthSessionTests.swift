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
        var tokenManager: TokenManager!
        let session = makeAuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: keychain
        )
        tokenManager = TokenManager(
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

    private func makeAuthSession(
        tokenManagerProvider: @escaping @MainActor @Sendable () -> TokenManagerProtocol = { MockTokenManager() },
        keychainService: KeychainServiceProtocol = MockKeychainService()
    ) -> AuthSession {
        AuthSession(
            tokenManagerProvider: tokenManagerProvider,
            keychainService: keychainService,
            userDefaults: UserDefaults(suiteName: "AuthSessionTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
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
