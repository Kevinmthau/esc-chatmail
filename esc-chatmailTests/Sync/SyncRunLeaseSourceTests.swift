import XCTest

/// What the sync-run lease reaches and what it must never be on the Mac, and
/// that a background task's entry takes no wait it cannot leave, pinned from
/// source (architecture review 2026-11, background-energy#2,
/// startup-lifecycle#3).
///
/// HONEST SCOPE: source text, not behavior. `SyncEngineRunLeaseTests` runs the
/// lease against a real run that is cancelled in its first request; no run
/// through the engine can succeed in a test, so the chain's cancellation
/// reaching the store maintenance after a successful run is pinned here. The
/// Mac's manager is never run by a test of the default plan.
final class SyncRunLeaseSourceTests: XCTestCase {

    // Revert-check: the `chain.cancel()` in the expiration that
    // `SyncEngine.triggerIncrementalSyncIfPossible` gives the lease. Without
    // it an expiration after the run succeeded leaves the store maintenance
    // running past the grant: the maintenance's own task is cancelled only
    // through its caller, the chain.
    func testForegroundEntry_leaseExpirationCancelsTheRunAndTheChain() throws {
        let source = try repositorySource("esc-chatmail/Services/Sync/SyncEngine.swift")
        let foreground = try body(of: "func triggerIncrementalSyncIfPossible(", in: source)

        let expiration = try XCTUnwrap(foreground.range(of: "lease.begin {"))
        let expirationBody = foreground[expiration.upperBound...].prefix(while: { $0 != "}" })
        XCTAssertTrue(expirationBody.contains("syncRunTask.task.cancel()"))
        XCTAssertTrue(expirationBody.contains("chain.cancel()"))
        XCTAssertFalse(expirationBody.contains("await"), "Nothing may be awaited at expiration")

        let leaseEnd = try XCTUnwrap(foreground.range(of: "defer { lease.end() }"))
        let maintenance = try XCTUnwrap(foreground.range(of: "runStoreMaintenanceAfterSync()"))
        XCTAssertLessThan(leaseEnd.lowerBound, maintenance.lowerBound, "The chain's defer covers the maintenance")
        XCTAssertLessThan(maintenance.lowerBound, expiration.lowerBound, "Begun after the chain exists")
    }

    // Revert-check: an `InertSyncRunBackgroundTaskManager.begin` that holds a
    // `ProcessInfo` activity, as the Mac's send lease does. `.userInitiated`
    // disables idle system sleep, against the Mac's decided pause for it, on
    // every 60-second run.
    func testMacSyncRunLease_holdsNoActivity() throws {
        let mac = try repositorySource("esc-chatmail/Platform/InertSyncRunBackgroundTaskManager.swift")
        let iOS = try repositorySource("esc-chatmail/Platform/UIKitSyncRunBackgroundTaskManager.swift")

        XCTAssertTrue(mac.hasPrefix("#if os(macOS)"))
        XCTAssertTrue(mac.contains("typealias PlatformSyncRunBackgroundTaskManager = InertSyncRunBackgroundTaskManager"))
        XCTAssertFalse(mac.contains("beginActivity"))
        XCTAssertFalse(mac.contains("expirationHandler()"), "The Mac's grant never expires")
        XCTAssertTrue(iOS.hasPrefix("#if os(iOS)"))
        XCTAssertTrue(iOS.contains("typealias PlatformSyncRunBackgroundTaskManager = UIKitSyncRunBackgroundTaskManager"))
    }

    /// A fired background task is completed only once its handler returns
    /// (`BackgroundSyncManager.runBackgroundTaskOperation`), so a handler
    /// parked behind a run it cannot leave keeps an expired task uncompleted.
    /// The background entry answers at once when the boundary is held, and the
    /// maintenance after it waits with the cancellation-aware
    /// `acquireRunWithTask`.
    ///
    /// HONEST SCOPE: guards against a wait added later; no line of today's
    /// code is removed to fail it.
    func testBackgroundEntry_takesNoWaitThatIgnoresCancellation() throws {
        let source = try repositorySource("esc-chatmail/Services/Sync/SyncEngine.swift")
        let manager = try repositorySource("esc-chatmail/Services/Background/BackgroundSyncManager.swift")
        let paths = [
            ("performIncrementalSyncForBackground", try body(of: "func performIncrementalSyncForBackground(", in: source)),
            ("prepareIncrementalSync", try body(of: "private func prepareIncrementalSync(", in: source)),
            ("storageAdmission", try body(of: "private func storageAdmission(", in: source)),
            ("BackgroundSyncManager", manager)
        ]

        for (name, text) in paths {
            for wait in ["waitUntilIdle(", "acquireRun(kind:", "waitForCurrentSyncToComplete("] {
                XCTAssertFalse(text.contains(wait), "\(name) waits with \(wait)")
            }
        }
        XCTAssertTrue(paths[1].1.contains("beginRunWithTask(kind: kind)"), "Admission answers at once")
    }

    /// The text from `signature` to the next function declared at the same
    /// indentation, which is where a member of `SyncEngine` ends.
    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "    " + signature), signature)
        let rest = source[start.upperBound...]
        let candidates = [rest.range(of: "\n    func "), rest.range(of: "\n    private func ")]
            .compactMap { $0?.lowerBound }
        let end = candidates.min() ?? rest.endIndex
        return String(rest[..<end])
    }
}
