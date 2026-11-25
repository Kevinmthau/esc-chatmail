import Foundation

/// The decisions of `HistoryRecoveryRepair`, as pure functions over values.
///
/// A history recovery lists only the mail after its window and only mail outside Spam
/// and Trash, so a stored row it did not list keeps the state it had before the gap.
/// The repair compares a batch of stored rows with three of Gmail's listings over the
/// same span (everything outside Spam and Trash, the inbox, the unread mail) and asks
/// Gmail about each row whose state the listings contradict. Only that answer changes a
/// row: a listing is a search, and its date bounds are not the row's internal date to
/// the second, so a row it leaves out proves nothing by itself.
enum HistoryRecoveryRepairPolicy {
    /// A stored row, as the comparison reads it.
    struct StoredRow: Equatable, Sendable {
        let messageId: String
        let internalDate: Date
        let hasInbox: Bool
        let isUnread: Bool
    }

    /// Gmail's answer for one row.
    enum Verdict: Equatable, Sendable {
        /// Gone from Gmail (404), or in Trash or Spam (or a draft): the row goes, as a
        /// history record of the same would have removed it.
        case remove
        /// Still in the mailbox: the row takes Gmail's inbox and unread state.
        case keep(hasInbox: Bool, isUnread: Bool)
    }

    /// The rows the listings contradict, in the stored order (newest first).
    static func candidates(
        stored: [StoredRow],
        listed: Set<String>,
        inInbox: Set<String>,
        unread: Set<String>
    ) -> [StoredRow] {
        stored.filter { row in
            !listed.contains(row.messageId)
                || row.hasInbox != inInbox.contains(row.messageId)
                || row.isUnread != unread.contains(row.messageId)
        }
    }

    /// Where the next batch starts once a batch is done with: `lowerBound` when every row
    /// asked about was answered, otherwise just above the newest row that was not (its
    /// internal date plus a millisecond, since the bound is exclusive and Gmail's dates
    /// are milliseconds). The rows newer than it are done, so a batch with more rows to
    /// ask about than one run's budget, or with a row Gmail keeps failing on, still moves
    /// the repair forward, and the rows left are compared again next run.
    static func nextUpperBound(
        lowerBound: Date,
        upperBound: Date,
        candidatesNewestFirst: [StoredRow],
        answered: Set<String>
    ) -> Date {
        guard let firstUnanswered = candidatesNewestFirst.first(where: { !answered.contains($0.messageId) }) else {
            return lowerBound
        }
        return min(firstUnanswered.internalDate.addingTimeInterval(0.001), upperBound)
    }

    /// The progress to stage once the plan was applied: rows `apply` left alone because
    /// they wait now (a user's action queued between the plan and its application) keep
    /// the bound above them, as a row that waited at planning does, never below the bound
    /// the repair was owed at.
    static func progressAfterApply(
        planned: HistoryRecoveryRepair.Progress,
        owedUpperBound: Date,
        skippedDates: [Date]
    ) -> HistoryRecoveryRepair.Progress {
        guard case .advances(let bound) = planned, let newestSkipped = skippedDates.max() else {
            return planned
        }
        return .advances(to: min(max(bound, newestSkipped.addingTimeInterval(0.001)), owedUpperBound))
    }

    /// Runs in a row that may leave the bound where it was before the repair steps past
    /// what holds it.
    static let maximumRunsWithoutProgress = 5

    /// The progress to stage, and the count to keep, given how many runs in a row before
    /// this one left the bound where it was. A row Gmail fails on every time, a pending
    /// action that never ends, or a listing that keeps failing would otherwise stop the
    /// repair for good, and every older row with it. After
    /// `maximumRunsWithoutProgress` such runs the bound steps to `escapeBound`: just
    /// below the one row that holds it (that row is given up on), or a failed batch's
    /// oldest row (that batch is given up on).
    static func progressAfterStall(
        _ progress: HistoryRecoveryRepair.Progress,
        owedUpperBound: Date,
        runsWithoutProgressBefore: Int,
        escapeBound: Date?
    ) -> (progress: HistoryRecoveryRepair.Progress, runsWithoutProgress: Int) {
        switch progress {
        case .finished:
            return (.finished, 0)
        case .advances(let bound) where bound < owedUpperBound:
            return (progress, 0)
        case .advances, .holds:
            let runs = runsWithoutProgressBefore + 1
            guard runs >= maximumRunsWithoutProgress,
                  let escapeBound,
                  escapeBound < owedUpperBound else {
                return (progress, runs)
            }
            return (.advances(to: escapeBound), 0)
        }
    }

    /// What Gmail's labels for a row say.
    static func verdict(forLabelIds labelIds: [String]?) -> Verdict {
        let labels = Set(labelIds ?? [])
        if !labels.isDisjoint(with: MessagePersister.excludedMailboxLabelIDs) {
            return .remove
        }
        return .keep(hasInbox: labels.contains("INBOX"), isUnread: labels.contains("UNREAD"))
    }

    /// The Gmail query for one span of internal dates, widened by a second at each end:
    /// a row the widening adds is only asked about, never changed for it.
    static func query(_ scope: String, from lowerBound: Date, before upperBound: Date) -> String {
        let after = Int(lowerBound.timeIntervalSince1970.rounded(.down)) - 1
        let before = Int(upperBound.timeIntervalSince1970.rounded(.up)) + 1
        return "\(scope) after:\(after) before:\(before)"
    }
}
