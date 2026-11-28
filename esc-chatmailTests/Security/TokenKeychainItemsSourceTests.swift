import XCTest

/// Pins from source that the app never writes or reads a token to or from its own
/// keychain items again (`KeychainService.Key.googleAccessToken`, `.googleRefreshToken`).
///
/// Until 2026-11-28 every launch's restore wrote both, inside the credential-cleanup
/// marker's transaction, for copies only a cold cache read and that the restore had
/// already put in the cache (architecture review 2026-11, `account-boundary-auth#4`).
/// `TokenManager`'s cache is now the only copy, adopted in memory. A test of the
/// running code sees only the paths it drives, so this reads every app file: a write
/// added anywhere, or a read that would hand a request a token GoogleSignIn did not
/// give it, fails here.
final class TokenKeychainItemsSourceTests: XCTestCase {
    private static let tokenKeys = ["googleAccessToken", "googleRefreshToken"]

    // Revert-check: fails if `TokenManager.adoptTokens(access:expirationDate:ifCacheEpochMatches:)`
    // saves the token again (`keychainService.saveCodable(…, for: KeychainService.Key.googleAccessToken.rawValue, …)`),
    // or if `getCurrentToken` reads the item again (`loadCodable(…, for: KeychainService.Key.googleAccessToken.rawValue)`).
    func testTokenKeychainItems_areOnlyDeletedOrProbedForPresence() throws {
        var offending: [String] = []
        var deleteSites = 0
        for path in try repositorySwiftFilePaths(under: "esc-chatmail") {
            let lines = try repositorySource(path).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("///"), !code.hasPrefix("//"),
                      Self.tokenKeys.contains(where: { code.contains($0) }) else {
                    continue
                }
                if Self.isAllowed(code, in: path) {
                    if code.contains("delete(for:") { deleteSites += 1 }
                    continue
                }
                offending.append("\(path):\(index + 1): \(code)")
            }
        }

        XCTAssertEqual(
            offending,
            [],
            "A token item is only ever deleted, declared, or probed for presence"
        )
        // Four: `clearTokens`' two and `removeLegacyTokenItemsIfNeeded`'s two. Fewer means
        // a sign-out or the first adoption leaves an earlier build's refresh token behind.
        XCTAssertEqual(deleteSites, 4, "Both items are deleted by the sign-out and by the first adoption")
    }

    private static func isAllowed(_ code: String, in path: String) -> Bool {
        if code.hasPrefix("try keychainService.delete(for: KeychainService.Key.googleAccessToken.rawValue)")
            || code.hasPrefix("try keychainService.delete(for: KeychainService.Key.googleRefreshToken.rawValue)") {
            return path == "esc-chatmail/Services/Security/TokenManager.swift"
        }
        switch path {
        case "esc-chatmail/Services/Security/KeychainService.swift":
            // The keys' declarations.
            return code.hasPrefix("case googleAccessToken = ") || code.hasPrefix("case googleRefreshToken = ")
        case "esc-chatmail/Services/Security/AuthSession.swift":
            // `hasPersistedBackgroundCredentialMaterial`'s list, which reads presence only.
            return code == "KeychainService.Key.googleAccessToken," || code == ".googleRefreshToken,"
        default:
            return false
        }
    }
}
