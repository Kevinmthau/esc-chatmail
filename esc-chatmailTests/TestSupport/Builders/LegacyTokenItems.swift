import Foundation
@testable import esc_chatmail

/// The two token items builds before 2026-11-28 wrote at every launch
/// (`KeychainService.Key.googleAccessToken`, `.googleRefreshToken`), so a
/// test can stand in for an install that still has them. The access token's
/// item has the shape of those builds' `TokenInfo`, which they read back with
/// the keychain's `JSONDecoder`, so code that read the item again would be
/// handed its `accessToken`.
enum LegacyTokenItems {
    private struct AccessTokenItem: Codable {
        let accessToken: String
        let refreshToken: String?
        let expirationDate: Date
        let scope: String?
    }

    static func seed(
        in keychain: MockKeychainService,
        accessToken: String = "legacy-access",
        refreshToken: String = "legacy-refresh",
        expirationDate: Date = Date().addingTimeInterval(3_600)
    ) throws {
        try keychain.saveCodable(
            AccessTokenItem(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expirationDate: expirationDate,
                scope: nil
            ),
            for: KeychainService.Key.googleAccessToken.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        try keychain.saveString(
            refreshToken,
            for: KeychainService.Key.googleRefreshToken.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
    }

    /// Whether either item is in `keychain`.
    static func anyStored(in keychain: MockKeychainService) -> Bool {
        keychain.exists(for: KeychainService.Key.googleAccessToken.rawValue)
            || keychain.exists(for: KeychainService.Key.googleRefreshToken.rawValue)
    }
}
