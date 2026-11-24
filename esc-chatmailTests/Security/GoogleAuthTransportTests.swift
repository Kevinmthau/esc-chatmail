import XCTest
@testable import esc_chatmail

/// The launch restore's deadline is on AppAuth's transport (`GoogleAuthTransport`), never
/// on the restore's wait, which must not end while GoogleSignIn is still running.
final class GoogleAuthTransportTests: XCTestCase {
    func testMakeSession_boundsEveryTokenRequest() {
        let configuration = GoogleAuthTransport.makeSession().configuration

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    // Revert-check: fails if `configureGoogleSignIn()` stops calling
    // `GoogleAuthTransport.install()`. The test host runs the app's initializer, so
    // AppAuth would then send through the shared session, whose request timeout is 60
    // seconds of silence and whose resource timeout is a week.
    func testAppInitializer_installedTheBoundedSessionForAppAuth() {
        let configuration = GoogleAuthTransport.installedSession.configuration

        XCTAssertEqual(configuration.timeoutIntervalForRequest, GoogleAuthTransport.requestTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, GoogleAuthTransport.resourceTimeout)
        XCTAssertFalse(GoogleAuthTransport.installedSession === URLSession.shared)
    }

    /// The restore's wait in `AuthSession` must stay unbounded: a timeout there releases
    /// the auth-transition gate while GoogleSignIn's flow still owns its one slot.
    func testRestoreWait_hasNoSoftTimeout() throws {
        let source = try repositorySource("esc-chatmail/Services/Security/AuthSession.swift")
        let start = try XCTUnwrap(source.range(of: "func restorePreviousSignIn() async -> AuthRestoreOutcome {"))
        let end = try XCTUnwrap(source.range(of: "func signIn(presenting", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]

        XCTAssertTrue(body.contains("await withCheckedContinuation"))
        XCTAssertFalse(body.contains("withSoftTimeout"))
        XCTAssertFalse(body.contains("withTimeout"))
    }
}
