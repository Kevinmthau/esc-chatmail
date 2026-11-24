import Foundation

/// Keeps one stored row that kills the process from stopping a launch pass for
/// good (architecture review 2026-11, `startup-lifecycle#6`).
///
/// The body-reading launch passes (the preview re-derivation, the blank-preview
/// backfill, the rich-content verdict backfill) write their cursor only after a
/// batch saves. A row whose derivation crashed the app, or ran so long that the
/// app was killed under it, was therefore read again at the same cursor on every
/// launch, and the pass never got past it. Each pass now marks the row it is
/// deriving (`beginRow`) and clears the mark when the derivation returns
/// (`endRow`). A mark left by another launch is a death with that row in flight
/// and is counted when the pass next starts (`recoveringFromEarlierLaunches`);
/// after `deathsBeforeQuarantine` of them the row is quarantined, and the pass
/// leaves it as it is: its stored preview stays, and its verdict stays unknown,
/// so its bubble derives as before when shown. Nothing here touches the passes'
/// checkpoints or completion flags, which conversation maintenance reads, and
/// the cursor moves past a quarantined row in the normal way.
///
/// A death is counted by row, not by batch, because the app is also ended while
/// a pass runs for reasons that have nothing to do with the row (a force quit, a
/// kill while suspended): such a death lands on whichever row was in flight, and
/// a row is quarantined only once that has happened to it three times.
///
/// Every key embeds the pass's migration key. The re-derivation's and the
/// verdict backfill's embed their derivation version and verdict epoch, so a
/// bump gives every row a fresh chance under the new code; the blank-preview
/// backfill's key is fixed, and that pass runs once.
///
/// One guard per run of a pass, and the passes' running flags keep two runs
/// of one pass apart: a guard built while another run of its pass had a row
/// in flight would clear that run's mark. What a pass writes is bounded: one mark, at most
/// `maximumRememberedRows` struck rows and as many quarantined ones.
///
/// HONEST SCOPE: whether a mark written just before a crash reaches the disk
/// has not been measured; `UserDefaults` persists through `cfprefsd`, which
/// outlives the app, but a write still in the app's own queue when it crashes
/// is lost, and that death then goes uncounted. It covers the launch passes
/// only: sync ingest and bubble loads derive the same body unguarded.
///
/// `@unchecked Sendable`: a pass reads it on its context's queue. Its own state
/// is immutable (`let`), and the store it writes is `UserDefaults` (thread-safe)
/// in the app and a locked store in tests.
struct LaunchPassRowQuarantine: @unchecked Sendable {
    /// Deaths with one row in flight before the row is quarantined.
    static let deathsBeforeQuarantine = 3
    /// Bounds the struck and the quarantined lists a pass keeps.
    static let maximumRememberedRows = 64

    /// Names this process, so a mark a pass left in this same launch (it never
    /// does: `endRow` always runs) is never counted as a death.
    static let currentLaunchID = UUID().uuidString

    private let store: MigrationFlagStore
    private let inFlightKey: String
    private let launchID: String
    private let quarantinedRows: Set<String>

    /// Counts a mark another launch left as a death of its row, quarantines the
    /// row if that was its last chance, and returns the guard for this run.
    static func recoveringFromEarlierLaunches(
        passKey: String,
        store: MigrationFlagStore,
        launchID: String = currentLaunchID
    ) -> LaunchPassRowQuarantine {
        let inFlightKey = inFlightKey(forPassKey: passKey)
        let strikesKey = deathsKey(forPassKey: passKey)
        let quarantineKey = quarantineKey(forPassKey: passKey)
        var quarantined = decodeList(store.string(forKey: quarantineKey))

        if let mark = store.string(forKey: inFlightKey),
           let separator = mark.firstIndex(of: "|") {
            let markLaunch = String(mark[..<separator])
            let row = String(mark[mark.index(after: separator)...])
            if markLaunch != launchID, !row.isEmpty {
                var strikes = decodeList(store.string(forKey: strikesKey))
                strikes.append(row)
                let deaths = strikes.filter { $0 == row }.count
                if deaths >= deathsBeforeQuarantine {
                    strikes.removeAll { $0 == row }
                    if !quarantined.contains(row) {
                        quarantined.append(row)
                    }
                    quarantined = Array(quarantined.suffix(maximumRememberedRows))
                    store.setString(encodeList(quarantined), forKey: quarantineKey)
                    Log.warning(
                        "Launch pass quarantined row \(Log.hashIdentifier(row)) after \(deaths) deaths with it in flight",
                        category: .conversation
                    )
                } else {
                    Log.warning(
                        "Launch pass row \(Log.hashIdentifier(row)) was in flight when an earlier launch ended (\(deaths) of \(deathsBeforeQuarantine))",
                        category: .conversation
                    )
                }
                store.setString(encodeList(Array(strikes.suffix(maximumRememberedRows))), forKey: strikesKey)
            }
        }
        if store.string(forKey: inFlightKey) != nil {
            store.setString(nil, forKey: inFlightKey)
        }
        return LaunchPassRowQuarantine(
            store: store,
            inFlightKey: inFlightKey,
            launchID: launchID,
            quarantinedRows: Set(quarantined)
        )
    }

    /// The row in flight and its launch, `launch|row`.
    static func inFlightKey(forPassKey passKey: String) -> String {
        passKey + ".rowInFlight"
    }

    /// One line per death not yet enough to quarantine its row.
    static func deathsKey(forPassKey passKey: String) -> String {
        passKey + ".rowDeaths"
    }

    /// One line per quarantined row.
    static func quarantineKey(forPassKey passKey: String) -> String {
        passKey + ".quarantinedRows"
    }

    func isQuarantined(_ rowID: String) -> Bool {
        quarantinedRows.contains(rowID)
    }

    /// Marks `rowID` as the row being derived. Call `endRow()` when the
    /// derivation returns, whatever it returned.
    func beginRow(_ rowID: String) {
        store.setString(launchID + "|" + rowID, forKey: inFlightKey)
    }

    func endRow() {
        store.setString(nil, forKey: inFlightKey)
    }

    /// Message IDs hold no newline.
    private static func decodeList(_ encoded: String?) -> [String] {
        guard let encoded, !encoded.isEmpty else { return [] }
        return encoded.split(separator: "\n").map(String.init)
    }

    private static func encodeList(_ rows: [String]) -> String? {
        rows.isEmpty ? nil : rows.joined(separator: "\n")
    }
}
