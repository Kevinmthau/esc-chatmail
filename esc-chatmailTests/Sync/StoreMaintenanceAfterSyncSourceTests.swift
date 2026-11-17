import XCTest

/// Where the 6-hour store maintenance is started from, pinned from source.
///
/// HONEST SCOPE: source text, not behavior. `SyncEngine` runs an incremental
/// sync only against a whole scripted Gmail account, which no suite here has
/// (`SyncEngineStorageAdmissionTests` says the same of its own subject). What
/// the maintenance does once it is asked for is run for real in
/// `MaintenanceCleanupGateTests`: the per-sync cleanup leaves the passes
/// alone, and the request waits for the sync's run to end and takes the
/// exclusive run itself. These pin the two call sites that test cannot reach.
final class StoreMaintenanceAfterSyncSourceTests: XCTestCase {

    // Revert-check: a call to `runStoreMaintenanceIfDue`, or to the passes,
    // from `IncrementalSyncOrchestrator`. Everything there runs inside the
    // sync's run: the maintenance would wait for a boundary its own caller
    // holds, or, called without the exclusive run, hold the sync's run and
    // its `.syncCompleted` post for every store-wide pass, as it did.
    func testIncrementalSyncOrchestrator_runsOnlyThePerSyncCleanup() throws {
        let source = try repositorySource("esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift")

        XCTAssertTrue(source.contains("await dataCleanupService.runIncrementalCleanup()"))
        XCTAssertFalse(source.contains("runStoreMaintenanceIfDue"))
        XCTAssertFalse(source.contains("runMaintenanceCleanup"))
    }

    // Revert-check: the order in `SyncEngine.triggerIncrementalSyncIfPossible`
    // and `performIncrementalSyncForBackground`. Both ask for the maintenance
    // only after `runSyncTask` has returned, and `runSyncTask` ends the run
    // on every path before it returns.
    func testSyncEngine_asksForMaintenanceOnlyAfterTheRunHasEnded() throws {
        let source = try repositorySource("esc-chatmail/Services/Sync/SyncEngine.swift")
        let foreground = try body(of: "func triggerIncrementalSyncIfPossible(", in: source)
        let background = try body(of: "func performIncrementalSyncForBackground(", in: source)

        for (name, function) in [("foreground", foreground), ("background", background)] {
            let run = try XCTUnwrap(function.range(of: "runSyncTask("), name)
            let maintenance = try XCTUnwrap(function.range(of: "runStoreMaintenanceAfterSync()"), name)
            XCTAssertLessThan(run.lowerBound, maintenance.lowerBound, name)
            XCTAssertEqual(
                function.components(separatedBy: "runStoreMaintenanceAfterSync()").count, 2,
                "One request for each sync (\(name))"
            )
        }
        XCTAssertTrue(
            background.contains("if budget.allowsStoreMaintenance {"),
            "An app refresh has no time for the store-wide passes"
        )
        let orchestration = try body(of: "private func performIncrementalSyncInternal(", in: source)
        XCTAssertFalse(
            orchestration.contains("runStoreMaintenanceAfterSync"),
            "This function is the body of the run's own task"
        )
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
