import Foundation

/// Records that a recovery reset removed the store: the corrupt-store reset of the load
/// ladder or the launch screen's confirmed Reset Mailbox, neither of them a sign-out.
///
/// The restore that follows finds an empty store beside the old mailbox's body and
/// attachment files. Without this, nothing tells those files from another account's, so
/// the isolation gate ran the full account cleanup: it reset the store a second time (which
/// removes every backup, the one just written included) and moved the mailbox start to now,
/// so that only about five minutes of mail came back. CLAUDE.md says a store reset with no
/// sign-out moves nothing and re-lists up to `SyncConfig.initialSyncMaxWindow`.
/// `AuthSession.prepareLocalStoreForAuthenticatedAccount` reads it: with the marker set, the
/// files present, no rows, and the account being restored the one the keychain still names,
/// it removes the files and nothing else.
///
/// Written to the standard defaults by the production stack, before the removal: a crash
/// between the two leaves the marker beside a store that still has its rows, which the gate
/// treats as any store with rows. Every decision of the gate and every completed account
/// cleanup clears it; the fresh-install cleanup removes the whole defaults domain.
enum StoreRecoveryResetMarker {
    static let defaultsKey = "coreData.storeRemovedByRecovery.v1"

    static func mark(in defaults: UserDefaults) {
        defaults.set(true, forKey: defaultsKey)
    }

    static func isMarked(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
