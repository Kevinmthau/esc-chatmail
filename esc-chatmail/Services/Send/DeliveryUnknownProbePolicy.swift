import Foundation

/// When and how a send left as "Delivery unknown" is looked up in Gmail by its
/// deterministic RFC Message-ID, and what the answer means
/// (architecture review 2026-11, `outbound-and-actions#2`). `DeliveryUnknownProbe`
/// runs it inside an incremental sync run.
///
/// The lookup only ever *resolves* a send. Found means Gmail has it: the run
/// persists the message, whose echo consumes the record as any synced echo
/// does. Reliably not found means Gmail never received it: the record becomes
/// "Not sent" (`DeliveryUnknownResolution.stageNotSent`), which offers Edit and
/// resend. Nothing here ever sends; an answer that is not one of those two is
/// no verdict, and the record stays "Delivery unknown".
///
/// "Not found" is a claim about a non-idempotent send, and a wrong one lets the
/// user send the mail twice, so it rests on two witnesses, either of which
/// would have seen the message:
/// - Gmail's search (`rfc822msgid:` anywhere, Spam and Trash included) found
///   nothing, and its answer was complete: no next page;
/// - this run's history was complete and clean (`allowsProbing`): a terminal
///   slice with no failed fetch, after which a committed send's echo is in the
///   store, because while a record is ambiguous history admits even the
///   messages it would exclude (`HistoryProcessor`).
/// And it is asked only after a quiet period long past the send's own cap
/// (`NetworkConfig.sendResourceTimeout`), so that Gmail has finished with any
/// request it was still processing when the app gave up on it, and its search
/// has indexed the result.
enum DeliveryUnknownProbePolicy {
    /// How long after admission a send is first looked up. Far past the send's
    /// 300 s whole-request cap: the request is over on the device by then, and
    /// what remains is Gmail committing a body it had whole and indexing it.
    static let quietPeriod: TimeInterval = 60 * 60

    /// How long a send that was found, but whose echo did not consume its
    /// record, waits before it is looked up again.
    static let reprobeInterval: TimeInterval = 24 * 60 * 60

    /// Lookups per run, one list request each. Oldest admission first.
    static let maximumProbesPerRun = 3

    /// What the policy reads off an `OutboundSendMutationRecord`.
    struct Candidate: Equatable, Sendable {
        let optimisticMessageID: String
        let remoteCommittedMessageId: String?
        let remoteCommittedThreadId: String?
        let admittedAt: Date?
        let deliveryProbedAt: Date?
    }

    /// The run-level conditions: a run that may do expensive work (never an
    /// app refresh, whose half minute is not for this), and whose history this
    /// run was complete and clean, the second witness of "not found".
    static func allowsProbing(
        allowsExpensiveWork: Bool,
        historySliceIsTerminal: Bool,
        hadFetchFailures: Bool
    ) -> Bool {
        allowsExpensiveWork && historySliceIsTerminal && !hadFetchFailures
    }

    /// Only a terminal "Delivery unknown" record admitted by a build that
    /// stamps `admittedAt`, at least `quietPeriod` before the run started.
    /// Never an in-flight record (a live send until cold recovery converts
    /// it), never one without `admittedAt` (admitted before model 7; the oldest
    /// carried another Message-ID, so a search for the deterministic one proves
    /// nothing about them), and never a found one within `reprobeInterval`.
    static func isEligible(_ candidate: Candidate, runStartedAt: Date) -> Bool {
        guard candidate.remoteCommittedMessageId == OutboundSendRemoteState.ambiguousMessageID,
              candidate.remoteCommittedThreadId == nil,
              let admittedAt = candidate.admittedAt,
              runStartedAt.timeIntervalSince(admittedAt) >= quietPeriod else {
            return false
        }
        if let probedAt = candidate.deliveryProbedAt,
           runStartedAt.timeIntervalSince(probedAt) < reprobeInterval {
            return false
        }
        return true
    }

    /// The eligible candidates this run looks up, oldest admission first.
    static func candidatesToProbe(
        _ candidates: [Candidate],
        runStartedAt: Date
    ) -> [Candidate] {
        let eligible = candidates.filter { isEligible($0, runStartedAt: runStartedAt) }
        let ordered = eligible.sorted {
            ($0.admittedAt ?? .distantPast, $0.optimisticMessageID)
                < ($1.admittedAt ?? .distantPast, $1.optimisticMessageID)
        }
        return Array(ordered.prefix(maximumProbesPerRun))
    }

    /// The Gmail search for the send's own Message-ID, the one its MIME
    /// carried (`MimeBuilder.messageId(forOptimisticMessageID:)`), in every
    /// label including Spam and Trash.
    static func query(forOptimisticMessageID optimisticMessageID: String) -> String {
        let messageID = MimeBuilder.messageId(forOptimisticMessageID: optimisticMessageID)
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return "rfc822msgid:\(bare) in:anywhere"
    }

    /// What the search answered. Account-scoped failures and cancellation are
    /// not answers: the run rethrows them before asking for a verdict.
    enum Answer: Sendable {
        case listed(messageIDs: [String], nextPageToken: String?)
        case failed
    }

    enum Verdict: Equatable, Sendable {
        /// Gmail has the message: persist these IDs; the echo consumes the record.
        case found([String])
        /// Gmail has no such message: the record becomes "Not sent".
        case notFound
        /// No verdict: the record stays "Delivery unknown".
        case none
    }

    static func verdict(for answer: Answer) -> Verdict {
        switch answer {
        case .failed:
            return .none
        case .listed(let messageIDs, let nextPageToken):
            if !messageIDs.isEmpty {
                return .found(messageIDs)
            }
            // An empty page that still points at another is not a complete
            // answer; only an empty, final one is "not found".
            return nextPageToken == nil ? .notFound : .none
        }
    }
}
