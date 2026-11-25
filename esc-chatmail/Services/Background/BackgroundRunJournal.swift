#if os(iOS)
import Foundation

/// The last background-task runs, kept in the preferences so a shipped build can say
/// whether its tasks fire, expire, get blocked or fail (architecture review 2026-11,
/// `observability-errors#3`). Before it, a Release build logged nothing when a task fired,
/// completed, expired, was blocked or skipped while offline.
///
/// - Each entry is the task, its start and end, its outcome, whether it expired and what
///   iOS was told. No mailbox data, so it is not account data and a sign-out leaves it.
/// - It is written before the task's `setTaskCompleted` (`BackgroundTaskCompletionLatch`'s
///   `beforeReporting`): iOS may suspend the process as soon as that call returns.
/// - At most `capacity` entries; the oldest go first.
/// - Before the device's first unlock the preferences cannot be read: the list then reads
///   as empty and the entry written may be lost, or may replace the earlier history.
///   Nothing waits on it either way (not measured on a device).
/// - Shared via Share Diagnostics (`DiagnosticsReport`).
///
/// `@unchecked Sendable`: `lock` serializes every read and write of the stored list; the
/// stored properties are immutable.
final class BackgroundRunJournal: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// `appRefresh`, `processing`, or a maintenance task's identifier without the
        /// bundle prefix.
        let task: String
        let startedAt: Date
        let endedAt: Date
        let outcome: BackgroundRunOutcome
        /// Expiration won: iOS was told the run failed, whatever its outcome.
        let expired: Bool
        /// What `setTaskCompleted(success:)` was given.
        let reportedSuccess: Bool
    }

    static let defaultsKey = "diagnostics.backgroundRunJournal.v1"
    static let defaultCapacity = 20

    /// Hosted unit tests get a journal of their own, in a throwaway defaults suite: the
    /// background-sync suites run the real completion path, and must not write the app's
    /// preferences.
    static let shared: BackgroundRunJournal = RuntimeEnvironment.isRunningUnitTests
        ? BackgroundRunJournal(defaults: UserDefaults(suiteName: "BackgroundRunJournal.unitTests.\(UUID().uuidString)")!)
        : BackgroundRunJournal(defaults: .standard)

    private let defaults: UserDefaults
    private let capacity: Int
    private let lock = NSLock()

    init(defaults: UserDefaults, capacity: Int = BackgroundRunJournal.defaultCapacity) {
        self.defaults = defaults
        self.capacity = capacity
    }

    func append(_ entry: Entry) {
        lock.withLock {
            var stored = entriesLocked()
            stored.append(entry)
            if stored.count > capacity {
                stored.removeFirst(stored.count - capacity)
            }
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Oldest first. An unreadable list reads as empty and is replaced by the next append.
    func entries() -> [Entry] {
        lock.withLock { entriesLocked() }
    }

    private func entriesLocked() -> [Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Records a run and, for an expired or abnormal one, logs one warning line (which a
    /// Release build keeps; the outcome and task name are the app's own words).
    func record(task: String, startedAt: Date, endedAt: Date, outcome: BackgroundRunOutcome, reported: Bool, expired: Bool) {
        append(Entry(
            task: task,
            startedAt: startedAt,
            endedAt: endedAt,
            outcome: outcome,
            expired: expired,
            reportedSuccess: reported
        ))
        if expired || outcome.isAbnormal {
            let seconds = Int(endedAt.timeIntervalSince(startedAt).rounded())
            Log.warning(
                "Background task \(task) ended \(outcome.rawValue)\(expired ? " (expired)" : "") after \(seconds)s",
                category: .background
            )
        }
    }
}
#endif
