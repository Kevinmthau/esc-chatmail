import XCTest
@testable import esc_chatmail

/// `GoogleTokenRefresher.refreshTokens()`, GoogleSignIn's own refresh, over a
/// `StubGoogleUser` whose `refreshTokensIfNeeded` answers with an error
/// (architecture review 2026-11, `gap-wall-clock-time#2`). GoogleSignIn 9.0.0
/// hands AppAuth's -15, the refreshed ID token issued more than 600 s from the
/// device's clock, to that completion unchanged, and the refresher wrapped
/// every error as `refreshFailed`, which `TokenManager` retried: with a clock
/// set ahead past the token's expiry, three token requests at every request's
/// preflight.
@MainActor
final class GoogleTokenRefresherTests: XCTestCase {

    private var authSession: AuthSession!

    override func setUp() async throws {
        try await super.setUp()
        let placeholderTokenManager = MockTokenManager()
        authSession = AuthSession(
            tokenManagerProvider: { placeholderTokenManager },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "GoogleTokenRefresherTests-\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
    }

    override func tearDown() async throws {
        authSession = nil
        try await super.tearDown()
    }

    // Revert-check: fails if `GoogleTokenRefresher.refreshTokens()` wraps
    // GoogleSignIn's error as `TokenManagerError.refreshFailed(error)` again
    // instead of asking `GoogleTokenRefreshFailure.error(for:)`.
    func testRefreshTokens_googleSignInRefusedForTheDeviceClock_throwsRefreshedIDTokenRefused() async {
        authSession.currentUser = StubGoogleUser(
            email: "user@example.com",
            refreshError: NSError(
                domain: "org.openid.appauth.general",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "Issued at time is more than 600 seconds before or after the current time"]
            )
        )
        let refresher = GoogleTokenRefresher(authSession: authSession)

        do {
            let tokens = try await refresher.refreshTokens()
            XCTFail("Expected the refusal, got \(tokens.accessToken)")
        } catch TokenManagerError.refreshedIDTokenRefused(let underlying) {
            XCTAssertEqual((underlying as NSError).domain, "org.openid.appauth.general")
            XCTAssertEqual((underlying as NSError).code, -15)
        } catch {
            XCTFail("Expected TokenManagerError.refreshedIDTokenRefused, got \(error)")
        }
    }

    // Revert-check: fails if `GoogleTokenRefreshFailure.error(for:)` matches
    // AppAuth's general domain without the -15 code: a transport failure
    // would no longer be `refreshFailed`, which `TokenManager` retries.
    func testRefreshTokens_googleSignInFailsInTransport_throwsRefreshFailed() async {
        authSession.currentUser = StubGoogleUser(
            email: "user@example.com",
            refreshError: NSError(
                domain: "org.openid.appauth.general",
                code: -5,
                userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
            )
        )
        let refresher = GoogleTokenRefresher(authSession: authSession)

        do {
            let tokens = try await refresher.refreshTokens()
            XCTFail("Expected the transport error, got \(tokens.accessToken)")
        } catch TokenManagerError.refreshFailed(let underlying) {
            XCTAssertEqual((underlying as NSError).code, -5)
        } catch {
            XCTFail("Expected TokenManagerError.refreshFailed, got \(error)")
        }
    }
}
