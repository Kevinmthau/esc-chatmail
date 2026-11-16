import Foundation

/// Decides whether the incremental-sync send-as alias refresh should hit the
/// network. Aliases change rarely; a 24h TTL keeps the steady-state sync path
/// off the sendAs endpoint. The timestamp is recorded only after a successful
/// refresh and is keyed per account email so a stale entry can never suppress
/// a different account's first refresh after account switch.
struct SendAsAliasRefreshPolicy {

    static let ttl: TimeInterval = 24 * 60 * 60

    private static let keyPrefix = "sendAsAliasesLastRefresh."

    var userDefaults: UserDefaults = .standard
    var now: () -> Date = Date.init

    func shouldRefresh(accountEmail: String) -> Bool {
        let lastRefresh = userDefaults.double(forKey: Self.key(for: accountEmail))
        guard lastRefresh > 0 else { return true }
        return now().timeIntervalSince1970 - lastRefresh >= Self.ttl
    }

    func recordSuccessfulRefresh(accountEmail: String) {
        userDefaults.set(now().timeIntervalSince1970, forKey: Self.key(for: accountEmail))
    }

    /// Removes every account's timestamp. The key is named after the account's
    /// address, so one left behind keeps that address in the preferences
    /// after its sign-out; the cost of removing it is one alias refresh.
    static func forgetAllAccounts(in userDefaults: UserDefaults) {
        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            userDefaults.removeObject(forKey: key)
        }
    }

    private static func key(for accountEmail: String) -> String {
        keyPrefix + EmailNormalizer.normalize(accountEmail)
    }
}
