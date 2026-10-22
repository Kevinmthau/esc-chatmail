import Foundation
import CoreData

/// One-shot repair for conversation archive and Report Spam rows that were
/// abandoned before `GmailActionExecutor` chunked their batchModify.
///
/// Gmail rejects a batchModify naming more than 1,000 IDs. Until the chunking
/// fix, a conversation (or multi-selection) past that size sent them all in
/// one request, the non-retryable 4xx abandoned the row on its first attempt,
/// and the local archive or spam it described never reached Gmail. Chunking
/// stops new losses but does not revive those rows, so this pass resets the
/// recent ones to pending once and lets the normal processor re-run them.
extension PendingActionsManager {
    static let oversizedBatchRequeueMigrationKey = "hasRequeuedOversizedBatchPendingActionsV1"

    /// Only rows this young are replayed without asking. The `localModifiedAt`
    /// guard that keeps sync from overwriting a pending local change lapses
    /// after `SyncConfig.maxLocalModificationAge` (30 minutes), so an older
    /// archive or spam may since have been undone on another client, and
    /// replaying it would override the user. Older rows stay abandoned, where
    /// the abandoned-action banner leaves retrying to the user.
    static let oversizedBatchRequeueMaximumAge: TimeInterval = 24 * 60 * 60

    /// Runs at most once per install: a later abandonment of a large action
    /// has some other cause, and requeueing it on every launch would only
    /// repeat the failure. The flag is set only after a pass completes, so a
    /// refused lease or a failed fetch or save retries on the next launch.
    func requeueRecentOversizedBatchActionsIfNeeded(now: Date = Date()) async {
        guard !oneShotRepairDefaults.bool(forKey: Self.oversizedBatchRequeueMigrationKey) else {
            return
        }
        // Rewrites PendingAction rows under the non-exclusive lease, like any
        // other interactive local mutation, so the pass never queues behind a
        // long sync run and teardown still drains it before cleanup.
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest(),
              let lease = await syncRunCoordinator.acquireAccountWorkLease(
                kind: .pendingActions,
                for: accountWorkRequest
              ) else {
            return
        }

        let requeuedCount = await requeueRecentOversizedBatchActions(now: now, within: lease)
        // Released before processing starts: a lease holder must never wait
        // on the exclusive boundary.
        await syncRunCoordinator.endRun(lease)

        guard let requeuedCount else { return }
        oneShotRepairDefaults.set(true, forKey: Self.oversizedBatchRequeueMigrationKey)
        guard requeuedCount > 0 else { return }
        Log.info("Requeued \(requeuedCount) abandoned oversized archive/spam actions", category: .sync)
        await processAllPendingActions()
    }

    /// Returns the number of rows reset to pending, or nil when the pass could
    /// not complete (lease lost, fetch or save failed).
    private func requeueRecentOversizedBatchActions(
        now: Date,
        within lease: SyncRun
    ) async -> Int? {
        guard await syncRunCoordinator.isActiveRun(lease) else { return nil }

        let cutoff = now.addingTimeInterval(-Self.oversizedBatchRequeueMaximumAge)
        let batchLimit = GmailActionExecutor.gmailBatchModifyLimit
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "status == %@ AND actionType IN %@ AND createdAt >= %@",
                "abandoned",
                [
                    PendingAction.ActionType.archiveConversation.rawValue,
                    PendingAction.ActionType.reportSpam.rawValue
                ],
                cutoff as NSDate
            )

            do {
                var requeuedCount = 0
                for action in try context.fetch(request) {
                    guard let payload = action.payloadValue,
                          let data = payload.data(using: .utf8),
                          let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let messageIds = decoded["messageIds"] as? [String],
                          messageIds.count > batchLimit else {
                        continue
                    }
                    action.setValue("pending", forKey: "status")
                    action.setValue(Int16(0), forKey: "retryCount")
                    requeuedCount += 1
                }
                if context.hasChanges {
                    try context.save()
                }
                return requeuedCount
            } catch {
                Log.error("Failed to requeue oversized archive/spam actions", category: .sync, error: error)
                return nil
            }
        }
    }
}
