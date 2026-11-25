import CoreData
import Foundation

/// Brings the rows a history recovery did not visit in line with Gmail, one batch per
/// incremental run, newest first, until none is left (architecture review,
/// sync-engine#1).
///
/// A recovery (`IncrementalSyncOrchestrator.performHistoryRecoverySync`) lists only mail
/// after its window, and only mail outside Spam and Trash, then moves the cursor to the
/// profile's historyId. Whatever was archived, read, trashed, marked as spam or deleted
/// elsewhere during the gap, among rows stored before it, is in no history the new cursor
/// will ever return. The recovery's advancing save therefore stages an owed repair
/// (`HistoryRecoveryRepairCheckpointStore`), and each later run that may do expensive work
/// plans one batch here and applies it in its final save.
///
/// Four things keep it from changing what it must not:
/// - Rows of the user's own unsent mail (an optimistic or retained Not-sent row, whose ID
///   is the app's), rows the failure ledger owns, rows with a local change Gmail has not
///   had yet (`HistoryProcessor.hasPendingLocalModification`) and rows a pending action
///   names, by message or by conversation, are never asked about. A week offline leaves a
///   queued archive's `localModifiedAt` stale, and the pending action is what is left of
///   it. The same is asked again when the plan is applied.
/// - A row changes only on Gmail's own answer for it (`format=metadata`), never because a
///   listing left it out: see `HistoryRecoveryRepairPolicy`. Metadata is never persisted
///   as a message.
/// - Cancellation and account-scoped failures (`APIError.isAccountScopedSyncAbort`) are
///   rethrown and end the run, which commits nothing. A listing that fails keeps the
///   batch owed. A row Gmail does not answer for, and the rows past one run's budget, stay
///   owed with everything older than them; what was answered is applied
///   (`HistoryRecoveryRepairPolicy.nextUpperBound`).
/// - The plan is applied inside the run's final `ConversationRollupMutationSerializer`
///   block, keyed on its conversations, and saved with the checkpoint's progress, so the
///   changes and the record of them commit or die together.
struct HistoryRecoveryRepair {
    /// Rows compared in one run. A batch is cut at an internal date, so it can hold a few
    /// more where several rows share the second it is cut at.
    static let batchRowLimit = 250
    /// Rows asked about in one run.
    static let metadataRequestBudget = 100
    /// Pages read of each listing before the batch is left owed (a span far denser on
    /// Gmail than in the store).
    static let maxListingPages = 20
    private static let concurrentMetadataRequests = 8

    struct Plan: Sendable {
        /// Rows to remove: gone from Gmail, or in Trash or Spam.
        var removals: Set<String> = []
        /// Rows still in the mailbox whose state differs, with Gmail's state.
        var states: [String: (hasInbox: Bool, isUnread: Bool)] = [:]
        /// The conversations of every row the plan may change.
        var conversationObjectIDs: Set<NSManagedObjectID> = []
        var progress: Progress = .holds

        var isEmpty: Bool { removals.isEmpty && states.isEmpty }
    }

    enum Progress: Equatable, Sendable {
        /// The batch stays owed: its listings failed. Compare it again next run.
        case holds
        /// Rows before this internal date are still owed
        /// (`HistoryRecoveryRepairPolicy.nextUpperBound`).
        case advances(to: Date)
        /// No stored row is left to compare: the repair is done.
        case finished
    }

    let messageFetcher: MessageFetcher
    private let log = LogCategory.sync.logger

    init(messageFetcher: MessageFetcher) {
        self.messageFetcher = messageFetcher
    }

    // MARK: - Plan

    func planNextBatch(
        before upperBound: Date,
        in context: NSManagedObjectContext
    ) async throws -> Plan {
        try Task.checkCancellation()
        let batch = try await Self.storedBatch(before: upperBound, in: context)
        guard let lowerBound = batch.lowerBound else {
            var plan = Plan()
            plan.progress = .finished
            return plan
        }

        let listed: Set<String>
        let inInbox: Set<String>
        let unread: Set<String>
        do {
            listed = try await listAll(HistoryRecoveryRepairPolicy.query("-in:spam -in:trash", from: lowerBound, before: upperBound))
            inInbox = try await listAll(HistoryRecoveryRepairPolicy.query("in:inbox", from: lowerBound, before: upperBound))
            unread = try await listAll(HistoryRecoveryRepairPolicy.query("is:unread", from: lowerBound, before: upperBound))
        } catch {
            try Self.rethrowIfRunAborting(error)
            log.warning("History-recovery repair could not list its batch; it stays owed")
            return Plan()
        }

        let candidates = HistoryRecoveryRepairPolicy.candidates(
            stored: batch.rows,
            listed: listed,
            inInbox: inInbox,
            unread: unread
        )
        let asked = Array(candidates.prefix(Self.metadataRequestBudget))
        var plan = Plan()
        var answered = Set<String>()
        let storedById = Dictionary(uniqueKeysWithValues: batch.rows.map { ($0.messageId, $0) })

        for chunk in asked.map(\.messageId).chunked(into: Self.concurrentMetadataRequests) {
            try Task.checkCancellation()
            for (messageId, answer) in try await askGmail(about: chunk) {
                switch answer {
                case .verdict(.remove):
                    answered.insert(messageId)
                    plan.removals.insert(messageId)
                case .verdict(.keep(let hasInbox, let isUnread)):
                    answered.insert(messageId)
                    if let stored = storedById[messageId],
                       stored.hasInbox != hasInbox || stored.isUnread != isUnread {
                        plan.states[messageId] = (hasInbox, isUnread)
                    }
                case .unanswered:
                    break
                }
            }
        }

        let changing = plan.removals.union(plan.states.keys)
        plan.conversationObjectIDs = Set(changing.compactMap { batch.conversationByMessageId[$0] })
        plan.progress = .advances(to: HistoryRecoveryRepairPolicy.nextUpperBound(
            lowerBound: lowerBound,
            upperBound: upperBound,
            candidatesNewestFirst: candidates,
            answered: answered
        ))
        log.info(
            "History-recovery repair: compared \(batch.rows.count), asked \(asked.count), removing \(plan.removals.count), updating \(plan.states.count), progress \(plan.progress)"
        )
        return plan
    }

    private enum Answer {
        case verdict(HistoryRecoveryRepairPolicy.Verdict)
        case unanswered
    }

    private func askGmail(about messageIds: [String]) async throws -> [(String, Answer)] {
        let messageFetcher = self.messageFetcher
        let results = await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
            for messageId in messageIds {
                group.addTask {
                    do {
                        return (messageId, .success(try await messageFetcher.getMessageMetadata(id: messageId)))
                    } catch {
                        return (messageId, .failure(error))
                    }
                }
            }
            var results: [(String, Result<GmailMessage, Error>)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        var answers: [(String, Answer)] = []
        for (messageId, result) in results {
            switch result {
            case .success(let message):
                answers.append((messageId, .verdict(HistoryRecoveryRepairPolicy.verdict(forLabelIds: message.labelIds))))
            case .failure(let error):
                try Self.rethrowIfRunAborting(error)
                if case APIError.notFound = error {
                    answers.append((messageId, .verdict(.remove)))
                } else {
                    answers.append((messageId, .unanswered))
                }
            }
        }
        return answers
    }

    private func listAll(_ query: String) async throws -> Set<String> {
        var ids = Set<String>()
        var pageToken: String?
        for _ in 0..<Self.maxListingPages {
            try Task.checkCancellation()
            let page = try await messageFetcher.listMessages(query: query, pageToken: pageToken)
            ids.formUnion(page.messageIds)
            guard let next = page.nextPageToken else { return ids }
            pageToken = next
        }
        throw ListingTooLong()
    }

    private struct ListingTooLong: Error {}

    /// Cancellation and account-scoped failures end the run, which commits nothing.
    static func rethrowIfRunAborting(_ error: Error) throws {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
        if let apiError = error as? APIError, apiError.isAccountScopedSyncAbort {
            throw apiError
        }
    }

    // MARK: - Stored rows

    struct StoredBatch {
        var rows: [HistoryRecoveryRepairPolicy.StoredRow] = []
        var conversationByMessageId: [String: NSManagedObjectID] = [:]
        /// The oldest internal date in the batch; nil when no row is left.
        var lowerBound: Date?
    }

    /// The newest `batchRowLimit` rows before `upperBound`, and every other row of the
    /// second the batch is cut at, with the rows the repair never asks about left out.
    ///
    /// Internal for `ScaleQueryPlanTests`, which asks SQLite how it runs these fetches.
    static func storedBatch(
        before upperBound: Date,
        in context: NSManagedObjectContext
    ) async throws -> StoredBatch {
        try await context.perform {
            let upper = upperBound
            let newest = Message.fetchRequest()
            newest.predicate = NSPredicate(format: "internalDate < %@", upper as NSDate)
            newest.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: false)]
            newest.fetchLimit = batchRowLimit
            newest.relationshipKeyPathsForPrefetching = ["labels", "conversation"]
            var messages = try context.fetch(newest)
            guard let oldest = messages.last?.internalDate else {
                return StoredBatch()
            }
            if messages.count == batchRowLimit {
                // Every row of the second the batch is cut at, so the next batch starts
                // strictly before it and no row is skipped or compared twice.
                let ties = Message.fetchRequest()
                ties.predicate = NSPredicate(
                    format: "internalDate >= %@ AND internalDate < %@",
                    oldest as NSDate,
                    upper as NSDate
                )
                ties.relationshipKeyPathsForPrefetching = ["labels", "conversation"]
                messages = try context.fetch(ties)
            }

            let excluded = try excludedMessageIds(among: messages, in: context)
            var batch = StoredBatch(lowerBound: oldest)
            for message in messages where !excluded.contains(message.id) {
                batch.rows.append(HistoryRecoveryRepairPolicy.StoredRow(
                    messageId: message.id,
                    internalDate: message.internalDate,
                    hasInbox: message.labels?.contains { $0.id == "INBOX" } ?? false,
                    isUnread: message.isUnread
                ))
                if let conversation = message.conversation {
                    batch.conversationByMessageId[message.id] = conversation.objectID
                }
            }
            return batch
        }
    }

    /// The rows the repair never changes: the user's own unsent mail, rows the failure
    /// ledger owns, rows with a local change Gmail has not had, and rows a pending action
    /// names by message or by conversation. Call inside `context.perform`.
    static func excludedMessageIds(
        among messages: [Message],
        in context: NSManagedObjectContext
    ) throws -> Set<String> {
        guard !messages.isEmpty else { return [] }
        var excluded = Set<String>()
        for message in messages
        where OutboundSendDeliveryState.localOptimisticMessageID(for: message) != nil
            || HistoryProcessor.hasPendingLocalModification(message: message) {
            excluded.insert(message.id)
        }

        let ids = messages.map(\.id)
        let ledger = NSFetchRequest<NSDictionary>(entityName: "AbandonedSyncMessage")
        ledger.predicate = NSPredicate(format: "gmailMessageId IN %@", ids)
        ledger.resultType = .dictionaryResultType
        ledger.propertiesToFetch = ["gmailMessageId"]
        for row in try context.fetch(ledger) {
            if let id = row["gmailMessageId"] as? String { excluded.insert(id) }
        }

        let conversationIds = Set(messages.compactMap { $0.conversation?.id })
        let actions = PendingAction.fetchRequest()
        actions.predicate = NSPredicate(
            format: "status IN %@ AND (messageId IN %@ OR conversationId IN %@)",
            nonTerminalPendingActionStatuses,
            ids,
            Array(conversationIds)
        )
        let pending = try context.fetch(actions)
        let pendingMessageIds = Set(pending.compactMap(\.messageId))
        let pendingConversationIds = Set(pending.compactMap(\.conversationId))
        for message in messages
        where pendingMessageIds.contains(message.id)
            || message.conversation.map({ pendingConversationIds.contains($0.id) }) == true {
            excluded.insert(message.id)
        }
        return excluded
    }

    /// A pending action in one of these may still be sent to Gmail (`PendingActionProcessor`).
    static let nonTerminalPendingActionStatuses = ["pending", "processing", "failed"]

    // MARK: - Apply

    /// Applies `plan` in `context` and returns the conversations it changed. Only for the
    /// run's final rollup-serializer block, keyed on `plan.conversationObjectIDs`; the
    /// caller recomputes their rollups and saves. Every row is asked again whether the
    /// repair may change it, since the plan was made outside the block.
    static func apply(_ plan: Plan, in context: NSManagedObjectContext) async throws -> Set<NSManagedObjectID> {
        guard !plan.isEmpty else { return [] }
        let removals = plan.removals
        let states = plan.states
        return try await context.perform {
            let ids = Array(removals.union(states.keys))
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            request.relationshipKeyPathsForPrefetching = ["labels", "conversation"]
            let messages = try context.fetch(request)
            let excluded = try excludedMessageIds(among: messages, in: context)

            let inboxRequest = Label.fetchRequest()
            inboxRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
            inboxRequest.fetchLimit = 1
            let inboxLabel = try context.fetch(inboxRequest).first

            var changed = Set<NSManagedObjectID>()
            for message in messages where !excluded.contains(message.id) {
                let conversationID = message.conversation?.objectID
                if removals.contains(message.id) {
                    context.delete(message)
                    if let conversationID { changed.insert(conversationID) }
                    continue
                }
                guard let state = states[message.id] else { continue }
                var didChange = false
                let existingInbox = message.labels?.first { $0.id == "INBOX" }
                if state.hasInbox, existingInbox == nil, let inboxLabel {
                    message.addToLabels(inboxLabel)
                    didChange = true
                } else if !state.hasInbox, let existingInbox {
                    message.removeFromLabels(existingInbox)
                    didChange = true
                }
                if message.isUnread != state.isUnread {
                    message.isUnread = state.isUnread
                    didChange = true
                }
                if didChange, let conversationID { changed.insert(conversationID) }
            }
            return changed
        }
    }
}
