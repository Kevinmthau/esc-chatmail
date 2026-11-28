import XCTest
@testable import esc_chatmail

/// Both of `GoogleTokenRefresher`'s refreshes throw a failed request's error
/// through `GoogleTokenRefreshFailure`, GoogleSignIn's own included
/// (architecture review 2026-11, `gap-wall-clock-time#2`): AppAuth refuses
/// the ID token of Google's answer by the device's clock there too, and as
/// `refreshFailed` `TokenManager` asked again twice. Pinned from source:
/// GoogleSignIn's refresh needs a signed-in `GIDGoogleUser`, which no hosted
/// test has, and the unit tests replace the refresher.
final class GoogleTokenRefresherSourceTests: XCTestCase {
    // Revert-check: fails if `GoogleTokenRefresher.refreshTokens()` wraps
    // GoogleSignIn's error as `TokenManagerError.refreshFailed(error)` again,
    // or if either refresher file builds a `refreshFailed` of its own.
    func testRefreshTokens_failedRequest_goesThroughTheSharedClassification() throws {
        let refresher = try source("esc-chatmail/Services/Security/GoogleTokenRefresher.swift")
        // Past the protocol, which declares both functions first.
        let implementation = try XCTUnwrap(refresher.range(of: "final class GoogleTokenRefresher"))
        let plainRefresh = try XCTUnwrap(refresher.range(
            of: "func refreshTokens() async throws",
            range: implementation.upperBound..<refresher.endIndex
        ))
        let forcedRefresh = try XCTUnwrap(refresher.range(
            of: "func forceRefreshTokens() async throws",
            range: plainRefresh.upperBound..<refresher.endIndex
        ))
        let plainRefreshBody = refresher[plainRefresh.upperBound..<forcedRefresh.lowerBound]
        XCTAssertTrue(
            plainRefreshBody.contains("user.refreshTokensIfNeeded"),
            "The body read is GoogleSignIn's own refresh"
        )
        XCTAssertTrue(
            plainRefreshBody.contains("continuation.resume(throwing: GoogleTokenRefreshFailure.error(for: error))"),
            "GoogleSignIn's error is classified as the forced refresh's is"
        )

        let forced = try source("esc-chatmail/Services/Security/GoogleForcedTokenRefresh.swift")
        XCTAssertTrue(forced.contains("continuation.resume(throwing: GoogleTokenRefreshFailure.error(for: error))"))

        for (name, text) in [("GoogleTokenRefresher", refresher), ("GoogleForcedTokenRefresh", forced)] {
            XCTAssertFalse(
                text.contains("refreshFailed("),
                "\(name) builds no refreshFailed of its own: only GoogleTokenRefreshFailure decides it"
            )
        }
    }

    private func source(_ path: String) throws -> String {
        try repositorySource(path)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
