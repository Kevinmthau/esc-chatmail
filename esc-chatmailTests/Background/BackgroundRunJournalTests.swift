#if os(iOS)
import XCTest
@testable import esc_chatmail

/// The last background-task runs, kept for Share Diagnostics (architecture review 2026-11,
/// `observability-errors#3`).
final class BackgroundRunJournalTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BackgroundRunJournalTests.\(UUID().uuidString)")!
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

    /// `reportsSuccess` is what each path of `performAuthoritativeSync` used to return.
    func testOutcomes_reportWhatTheRunUsedToReturn() {
        let succeeding: Set<BackgroundRunOutcome> = [.completed, .blockedNoRetry, .noSession, .maintenanceSucceeded]
        for outcome in BackgroundRunOutcome.allCases {
            XCTAssertEqual(outcome.reportsSuccess, succeeding.contains(outcome), outcome.rawValue)
        }
    }

    func testMaintenanceJournalName_dropsTheBundlePrefix() {
        XCTAssertEqual(BackgroundTaskRegistry.journalName(for: "com.esc.inboxchat.database.analyze"), "database.analyze")
        XCTAssertEqual(BackgroundTaskRegistry.journalName(for: "other.task"), "other.task")
    }
}
#endif
