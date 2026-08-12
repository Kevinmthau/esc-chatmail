import Foundation
import CoreData

/// Whether the pending-action processing loop may continue after an action's
/// outcome. `.stopRun` means the failure is account-scoped (authentication,
/// revoked credentials, or Gmail quota exhaustion): every remaining action
/// would fail identically, burning its retry budget toward abandonment for a
/// condition no action caused.
enum PendingActionRunDisposition {
    case continueRun
    case stopRun(PendingActionRunStopReason)
}

enum PendingActionRunStopReason {
    case authenticationError
    case credentialsRevoked
    case quotaExhausted
    case cancelled
}

/// Extension containing action processing logic for PendingActionsManager.
///
/// This handles the execution of pending actions, including retry logic,
/// status updates, and cleanup of completed actions.
extension PendingActionsManager {

    /// Resets stuck processing actions to failed so they can be retried.
    func recoverStuckProcessingActions() async {
        guard let syncRun = await acquirePendingActionRun() else { return }
        _ = await recoverStuckProcessingActions(within: syncRun)
        await syncRunCoordinator.endRun(syncRun)
    }

    func recoverStuckProcessingActions(within syncRun: SyncRun) async -> Bool {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return false }

        let context = coreDataStack.newBackgroundContext()
        let cutoffDate = Date().addingTimeInterval(-processingStaleInterval)

        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            let statusPredicate = NSPredicate(format: "status == %@", "processing")
            let stalePredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "lastAttempt == nil"),
                NSPredicate(format: "lastAttempt < %@", cutoffDate as NSDate)
            ])
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [statusPredicate, stalePredicate])

            do {
                let stuckActions = try context.fetch(request)
                guard !stuckActions.isEmpty else { return false }

                for action in stuckActions {
                    action.setValue("failed", forKey: "status")
                }
                try context.save()
                Log.warning("Recovered \(stuckActions.count) stuck pending actions", category: .sync)
                return true
            } catch {
                Log.error("Failed to recover stuck pending actions", category: .sync, error: error)
                return false
            }
        }
    }

    func hasActionsNeedingProcessing(within syncRun: SyncRun) async -> Bool {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return false }

        let context = coreDataStack.newBackgroundContext()
        let cutoffDate = Date().addingTimeInterval(-processingStaleInterval)
        let maxRetries = self.maxRetries

        return await context.perform {
            Self.hasActionsNeedingProcessing(
                in: context,
                maxRetries: maxRetries,
                staleProcessingCutoff: cutoffDate
            )
        }
    }

    private nonisolated static func hasActionsNeedingProcessing(
        in context: NSManagedObjectContext,
        maxRetries: Int,
        staleProcessingCutoff: Date
    ) -> Bool {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "PendingAction")
        request.predicate = actionsNeedingProcessingPredicate(
            maxRetries: maxRetries,
            staleProcessingCutoff: staleProcessingCutoff
        )
        request.fetchLimit = 1

        do {
            return (try context.count(for: request)) > 0
        } catch {
            Log.error("Failed to count pending actions", category: .sync, error: error)
            return false
        }
    }

    private nonisolated static func actionsNeedingProcessingPredicate(
        maxRetries: Int,
        staleProcessingCutoff: Date
    ) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "status == %@", "pending"),
            NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "status == %@", "failed"),
                NSPredicate(format: "retryCount < %d", maxRetries)
            ]),
            stuckProcessingPredicate(staleProcessingCutoff: staleProcessingCutoff)
        ])
    }

    private nonisolated static func stuckProcessingPredicate(
        staleProcessingCutoff: Date
    ) -> NSPredicate {
        let statusPredicate = NSPredicate(format: "status == %@", "processing")
        let stalePredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "lastAttempt == nil"),
            NSPredicate(format: "lastAttempt < %@", staleProcessingCutoff as NSDate)
        ])
        return NSCompoundPredicate(andPredicateWithSubpredicates: [statusPredicate, stalePredicate])
    }

    /// Fetches the next pending action to process.
    func fetchNextPendingAction(context: NSManagedObjectContext) async -> PendingAction? {
        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "status == %@ OR (status == %@ AND retryCount < %d)",
                "pending", "failed", self.maxRetries
            )
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            request.fetchLimit = 1

            do {
                return try context.fetch(request).first
            } catch {
                Log.error("Failed to fetch pending actions", category: .sync, error: error)
                return nil  // Will retry on next cycle
            }
        }
    }

    /// Processes a single pending action and reports whether the processing
    /// run may continue.
    @discardableResult
    func processAction(_ action: PendingAction, context: NSManagedObjectContext) async -> PendingActionRunDisposition {
        let objectID = action.objectID
        let actionType = action.actionTypeEnum
        let messageId = action.messageIdValue
        let sourceConversationId = action.conversationIdValue
        let payloadString = action.payloadValue
        let retryCount = action.retryCountValue
        let actionCreatedAt = action.createdAt

        // Mark as processing
        await updateActionStatus(objectID: objectID, status: "processing", context: context)

        do {
            let payload = parsePayload(payloadString)

            guard let type = actionType else {
                throw PendingActionError.invalidActionType
            }

            try await actionExecutor.execute(
                type: type,
                messageId: messageId,
                sourceConversationId: sourceConversationId,
                payload: payload
            )

            await updateActionStatus(objectID: objectID, status: "completed", context: context)
            await clearLocalModifications(
                actionType: type,
                messageId: messageId,
                payload: payload,
                completedActionCreatedAt: actionCreatedAt
            )

            Log.diagnostic(
                .pendingActions,
                level: .info,
                "Processed action: \(type.rawValue) for message: \(messageId ?? "N/A")",
                category: .sync
            )
            return .continueRun

        } catch {
            Log.error("Failed to process action: \(error)", category: .sync)

            if error is CancellationError || Task.isCancelled {
                // Account teardown cancels the registered processing task.
                // Cancellation is not a verdict on the user's action and must
                // not consume retry budget.
                await updateActionStatus(objectID: objectID, status: "pending", context: context)
                return .stopRun(.cancelled)
            }

            if let apiError = error as? APIError,
               let stopReason = pendingActionRunStopReason(for: apiError) {
                // Account-scoped, not a verdict on this action: requeue it
                // untouched (no retry-budget burn, no abandonment) and stop
                // the run. Authentication recovery or a later quota cycle
                // can retry it under a usable account session.
                Log.warning("Gmail account unavailable - requeueing action and stopping the pending-action run", category: .sync)
                await updateActionStatus(objectID: objectID, status: "pending", context: context)
                return .stopRun(stopReason)
            }

            let shouldRetry = shouldRetryError(error)
            await handleActionFailure(
                objectID: objectID,
                retryCount: retryCount,
                shouldRetry: shouldRetry,
                context: context
            )

            // Only apply backoff delay for retryable errors
            // Non-retryable errors (404, 401, validation) skip delay since retrying won't help
            if shouldRetry {
                // Wait before processing next action using exponential backoff
                // Uses the PRE-increment retryCount intentionally:
                // - After 1st failure (retryCount was 0): 2^0 * base = 2s
                // - After 2nd failure (retryCount was 1): 2^1 * base = 4s
                // - After 3rd failure (retryCount was 2): 2^2 * base = 8s, etc.
                let delay = baseRetryDelay * pow(2.0, Double(retryCount))
                guard await Task.sleepUnlessCancelled(nanoseconds: UInt64(min(delay, 30.0) * 1_000_000_000)) else {
                    return .stopRun(.cancelled)
                }
            }
            return .continueRun
        }
    }

    private func pendingActionRunStopReason(for error: APIError) -> PendingActionRunStopReason? {
        switch error {
        case .authenticationError:
            return .authenticationError
        case .credentialsRevoked:
            return .credentialsRevoked
        case .quotaExhausted:
            return .quotaExhausted
        default:
            return nil
        }
    }

    /// Parses a JSON payload string into a dictionary.
    func parsePayload(_ payloadString: String?) -> [String: Any]? {
        guard let payloadString = payloadString,
              let data = payloadString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    /// Updates the status of a pending action.
    func updateActionStatus(objectID: NSManagedObjectID, status: String, context: NSManagedObjectContext) async {
        await context.perform {
            do {
                guard let action = try context.existingObject(with: objectID) as? PendingAction else {
                    Log.warning("PendingAction not found for status update to '\(status)'", category: .sync)
                    return
                }
                action.setValue(status, forKey: "status")
                if status == "processing" {
                    action.setValue(Date(), forKey: "lastAttempt")
                }
                try context.save()
            } catch {
                Log.error("Failed to update action status to '\(status)'", category: .sync, error: error)
                // Status update failure is non-critical; action will be retried on next cycle
            }
        }
    }

    /// Determines if an error is retryable.
    /// Non-retryable errors (auth failures, not found, validation) should not waste retry attempts.
    private func shouldRetryError(_ error: Error) -> Bool {
        // Validation errors from our own code - never retry
        if error is PendingActionError { return false }

        // APIError decisions come from the canonical mapping on the type.
        if let apiError = error as? APIError {
            return apiError.isRetriableSameRequest
        }

        // For unknown errors, default to retry (conservative approach)
        return true
    }

    /// Handles a failed action by incrementing retry count.
    /// - Parameters:
    ///   - shouldRetry: If false, immediately abandons the action without incrementing retry count
    func handleActionFailure(objectID: NSManagedObjectID, retryCount: Int16, shouldRetry: Bool, context: NSManagedObjectContext) async {
        let shouldNotify = await context.perform {
            do {
                guard let action = try context.existingObject(with: objectID) as? PendingAction else {
                    Log.warning("PendingAction not found for failure handling", category: .sync)
                    return false
                }

                // If error is not retryable, abandon immediately without wasting retry attempts
                if !shouldRetry {
                    action.setValue("abandoned", forKey: "status")
                    Log.warning("Action abandoned (non-retryable error)", category: .sync)
                    try context.save()
                    return true  // Notify UI
                }

                let newRetryCount = retryCount + 1
                action.setValue(newRetryCount, forKey: "retryCount")

                if newRetryCount >= Int16(self.maxRetries) {
                    // Mark as abandoned instead of failed - this is permanent
                    action.setValue("abandoned", forKey: "status")
                    Log.warning("Action permanently failed after \(self.maxRetries) retries - marked as abandoned", category: .sync)
                    try context.save()
                    return true  // Notify UI
                } else {
                    action.setValue("failed", forKey: "status")
                    Log.info("Action will be retried (attempt \(newRetryCount + 1)/\(self.maxRetries))", category: .sync)
                    try context.save()
                    return false
                }
            } catch {
                Log.error("Failed to record action failure", category: .sync, error: error)
                // Failure recording failed; action may be processed again
                return false
            }
        }

        // Post notification on main thread if action was permanently abandoned
        if shouldNotify {
            await MainActor.run {
                NotificationCenter.default.post(name: .pendingActionFailed, object: nil)
            }
        }
    }

    /// Clears local modification flags after successful sync, unless another
    /// live action or a newer optimistic mutation still needs the marker.
    func clearLocalModifications(
        actionType: PendingAction.ActionType,
        messageId: String?,
        payload: [String: Any]?,
        completedActionCreatedAt: Date
    ) async {
        let completedTargetIDs = Self.executedTargetMessageIDs(
            actionType: actionType,
            messageId: messageId,
            payload: payload
        )
        guard !completedTargetIDs.isEmpty else { return }

        // This short-lived context uses store-trump only for reconciliation
        // marker clearing. If a newer optimistic mutation commits after the
        // timestamp fetch but before this save, its marker must win instead
        // of being overwritten by the completed action's nil.
        let markerContext = coreDataStack.newBackgroundContext()
        markerContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy

        let stagedChanges = await markerContext.perform {
            do {
                let actionRequest = NSFetchRequest<PendingAction>(entityName: "PendingAction")
                actionRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "status IN %@", ["pending", "processing", "failed"]),
                    NSCompoundPredicate(orPredicateWithSubpredicates: [
                        NSPredicate(format: "messageId IN %@", Array(completedTargetIDs)),
                        NSPredicate(format: "payload != nil")
                    ])
                ])
                actionRequest.fetchBatchSize = 50

                var protectedTargetIDs = Set<String>()
                for action in try markerContext.fetch(actionRequest) {
                    let targetIDs = Self.executedTargetMessageIDs(
                        actionType: action.actionTypeEnum,
                        messageId: action.messageIdValue,
                        payloadString: action.payloadValue
                    )
                    protectedTargetIDs.formUnion(targetIDs.intersection(completedTargetIDs))
                }

                let clearableTargetIDs = completedTargetIDs.subtracting(protectedTargetIDs)
                guard !clearableTargetIDs.isEmpty else { return false }

                let messageRequest = NSFetchRequest<Message>(entityName: "Message")
                messageRequest.predicate = NSPredicate(
                    format: "id IN %@ AND localModifiedAt != nil AND localModifiedAt <= %@",
                    Array(clearableTargetIDs),
                    completedActionCreatedAt as NSDate
                )

                for message in try markerContext.fetch(messageRequest) {
                    message.setValue(nil, forKey: "localModifiedAt")
                }
                return markerContext.hasChanges
            } catch {
                // Failing closed leaves reconciliation protection in place;
                // the 30-minute maxLocalModificationAge staleness escape in
                // HistoryProcessor.hasPendingLocalModification is the backstop
                // if no later scan clears the marker.
                Log.debug("Failed to clear completed pending-action modifications", category: .sync)
                return false
            }
        }

        guard stagedChanges else { return }
        await lifecycleHooks.localModificationClearDidStageChanges?()

        await markerContext.perform {
            // Failing closed leaves reconciliation protection in place; the
            // 30-minute maxLocalModificationAge staleness escape in
            // HistoryProcessor.hasPendingLocalModification is the backstop if
            // no later scan clears the marker.
            _ = markerContext.saveOrLog(
                operation: "clear completed pending-action modifications",
                category: .sync
            )
        }
    }

    private nonisolated static func executedTargetMessageIDs(
        actionType: PendingAction.ActionType?,
        messageId: String?,
        payload: [String: Any]?
    ) -> Set<String> {
        var directMessageIDs = Set<String>()
        if let messageId, !messageId.isEmpty {
            directMessageIDs.insert(messageId)
        }
        let payloadMessageIDs = Set(
            (payload?["messageIds"] as? [String] ?? []).filter { !$0.isEmpty }
        )

        guard let actionType else {
            // An invalid live row will be abandoned when processed. Until
            // then, retain every marker it might plausibly describe.
            return directMessageIDs.union(payloadMessageIDs)
        }

        switch actionType {
        case .markRead:
            return payloadMessageIDs.isEmpty ? directMessageIDs : payloadMessageIDs
        case .archiveConversation, .reportSpam:
            return payloadMessageIDs
        case .markUnread, .archive, .star, .unstar:
            return directMessageIDs
        }
    }

    private nonisolated static func executedTargetMessageIDs(
        actionType: PendingAction.ActionType?,
        messageId: String?,
        payloadString: String?
    ) -> Set<String> {
        let payload: [String: Any]?
        if let payloadString,
           let data = payloadString.data(using: .utf8) {
            payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            payload = nil
        }
        return executedTargetMessageIDs(
            actionType: actionType,
            messageId: messageId,
            payload: payload
        )
    }

    /// Cleans up completed actions from the database.
    func cleanupCompletedActions(context: NSManagedObjectContext) async {
        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = PendingActionPredicates.completed

            do {
                let completedActions = try context.fetch(request)
                guard !completedActions.isEmpty else { return }

                for action in completedActions {
                    context.delete(action)
                }
                try context.save()
                Log.diagnostic(.pendingActions, "Cleaned up \(completedActions.count) completed actions", category: .sync)
            } catch {
                // Non-critical: cleanup will happen on next cycle
                Log.diagnostic(.pendingActions, "Failed to cleanup completed actions", category: .sync)
            }
        }
    }
}
