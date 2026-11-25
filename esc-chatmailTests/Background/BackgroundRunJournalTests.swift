#if os(iOS)
import XCTest
@testable import esc_chatmail

/// The last background-task runs, kept for Share Diagnostics (architecture review 2026-11,
/// `observability-errors#3`).
final class BackgroundRunJournalTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "BackgroundRunJournalTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func entry(_ index: Int, outcome: BackgroundRunOutcome = .completed) -> BackgroundRunJournal.Entry {
        BackgroundRunJournal.Entry(
            task: "processing",
            startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            endedAt: Date(timeIntervalSince1970: TimeInterval(index) + 1),
            outcome: outcome,
            expired: false,
            reportedSuccess: outcome.reportsSuccess
        )
    }

    // Revert-check: fails if `append` stops trimming to `capacity`, or trims the newest.
    func testAppend_pastCapacity_keepsTheNewest() {
        let journal = BackgroundRunJournal(defaults: makeDefaults(), capacity: 3)

        (0..<5).forEach { journal.append(entry($0)) }

        XCTAssertEqual(journal.entries(), (2..<5).map { entry($0) })
    }

    func testEntries_surviveANewJournalOnTheSameDefaults() {
        let defaults = makeDefaults()
        BackgroundRunJournal(defaults: defaults).append(entry(1, outcome: .failed))

        XCTAssertEqual(BackgroundRunJournal(defaults: defaults).entries(), [entry(1, outcome: .failed)])
    }

    func testUnreadableList_readsEmpty_andTheNextAppendReplacesIt() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: BackgroundRunJournal.defaultsKey)
        let journal = BackgroundRunJournal(defaults: defaults)

        XCTAssertEqual(journal.entries(), [])
        journal.append(entry(7))
        XCTAssertEqual(journal.entries(), [entry(7)])
    }

    /// The outcomes reported as success. Which outcome each path returns is pinned in
    /// `BackgroundSyncManagerTests` (`testOutcome_eachExecutorResult_mapsToItsOwnOutcome`).
    func testOutcomes_reportedAsSuccess() {
        let succeeding: Set<BackgroundRunOutcome> = [
            .completed, .blockedNoRetry, .signedOut, .noSessionYet, .maintenanceSucceeded
        ]
        for outcome in BackgroundRunOutcome.allCases {
            XCTAssertEqual(outcome.reportsSuccess, succeeding.contains(outcome), outcome.rawValue)
        }
    }

    // Revert-check: fails if `append` stops replacing the run's own `started` entry: every
    // run would then appear twice, once as never completed.
    func testStartedEntry_isReplacedByItsCompletion_andStaysForARunThatNeverCompleted() {
        let journal = BackgroundRunJournal(defaults: makeDefaults())
        let start = Date(timeIntervalSince1970: 100)

        journal.recordStart(task: "processing", startedAt: start)
        journal.recordStart(task: "appRefresh", startedAt: start)
        journal.record(
            task: "processing",
            startedAt: start,
            endedAt: start.addingTimeInterval(5),
            outcome: .completed,
            reported: true,
            expired: false
        )

        XCTAssertEqual(journal.entries().map(\.task), ["appRefresh", "processing"])
        XCTAssertEqual(journal.entries().map(\.outcome), [.started, .completed])
    }

    // Revert-check: fails if the replacement stops matching on `startedAt`: the next run of
    // the same task would then remove a killed run's `started` entry, the only trace of it.
    func testStartedEntryOfAKilledRun_survivesTheNextRunOfTheSameTask() {
        let journal = BackgroundRunJournal(defaults: makeDefaults())
        let killed = Date(timeIntervalSince1970: 100)
        let next = Date(timeIntervalSince1970: 1_000)

        journal.recordStart(task: "processing", startedAt: killed)
        journal.recordStart(task: "processing", startedAt: next)
        journal.record(task: "processing", startedAt: next, endedAt: next, outcome: .completed, reported: true, expired: false)

        XCTAssertEqual(journal.entries().map(\.startedAt), [killed, next])
        XCTAssertEqual(journal.entries().map(\.outcome), [.started, .completed])
    }

    func testReport_carriesTheJournal() throws {
        BackgroundRunJournal.shared.append(entry(42, outcome: .noSessionYet))

        let runs = try XCTUnwrap(DiagnosticsReport.backgroundRunsForReport() as? [[String: Any]])

        XCTAssertEqual(runs.last?["outcome"] as? String, "noSessionYet")
        XCTAssertEqual(runs.last?["task"] as? String, "processing")
    }

    // Revert-check: fails if `BackgroundTaskRegistry.runTaskOperation` records the run
    // after `completionLatch.complete` (or not at all), or maps an expired handler's
    // success to anything but an expired, unreported entry.
    func testMaintenanceRunner_journalsBeforeItReports() async {
        let journal = BackgroundRunJournal(defaults: makeDefaults())
        let registry = BackgroundTaskRegistry(
            registerLaunchHandler: { _, _ in },
            submitTaskRequest: { _ in },
            pendingTaskIdentifiers: { [] },
            cancelPendingTaskRequest: { _ in },
            runJournal: journal
        )
        let completed = expectation(description: "completed")
        let seen = JournalAtReportProbe()
        var expire: (() -> Void)?

        registry.runTaskOperation(
            identifier: "com.esc.inboxchat.database.analyze",
            handler: {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
                return true
            },
            installExpirationHandler: { expire = $0 },
            onComplete: { reported in
                seen.record(journal.entries(), reported: reported)
                completed.fulfill()
            }
        )
        expire?()
        await fulfillment(of: [completed], timeout: 4)

        XCTAssertEqual(seen.reported, false)
        XCTAssertEqual(seen.entries.count, 1)
        XCTAssertEqual(seen.entries.first?.task, "database.analyze")
        XCTAssertEqual(seen.entries.first?.outcome, .maintenanceSucceeded)
        XCTAssertEqual(seen.entries.first?.expired, true)
        XCTAssertEqual(seen.entries.first?.reportedSuccess, false)
    }

    func testMaintenanceJournalName_dropsTheBundlePrefix() {
        XCTAssertEqual(BackgroundTaskRegistry.journalName(for: "com.esc.inboxchat.database.analyze"), "database.analyze")
        XCTAssertEqual(BackgroundTaskRegistry.journalName(for: "other.task"), "other.task")
    }
}
/// What the journal held when the task was reported. `@unchecked Sendable`: `lock` guards
/// both fields.
private final class JournalAtReportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [BackgroundRunJournal.Entry] = []
    private var storedReported: Bool?

    var entries: [BackgroundRunJournal.Entry] { lock.withLock { storedEntries } }
    var reported: Bool? { lock.withLock { storedReported } }

    func record(_ entries: [BackgroundRunJournal.Entry], reported: Bool) {
        lock.withLock {
            storedEntries = entries
            storedReported = reported
        }
    }
}
#endif
