import Foundation
import CoreData

/// Extension containing action processing logic for PendingActionsManager.
///
/// This handles the execution of pending actions, including retry logic,
/// status updates, and cleanup of completed actions.
extension PendingActionsManager {

    /// Resets stuck processing actions to failed so they can be retried.
    func recoverStuckProcessingActions() async {
        let context = coreDataStack.newBackgroundContext()
        let cutoffDate = Date().addingTimeInterval(-processingStaleInterval)

        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            let statusPredicate = NSPredicate(format: "status == %@", "processing")
            let stalePredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "lastAttempt == nil"),
                NSPredicate(format: "lastAttempt < %@", cutoffDate as NSDate)
            ])
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [statusPredicate, stalePredicate])

            do {
                let stuckActions = try context.fetch(request)
                guard !stuckActions.isEmpty else { return }

                for action in stuckActions {
                    action.setValue("failed", forKey: "status")
                }
                try context.save()
                Log.warning("Recovered \(stuckActions.count) stuck pending actions", category: .sync)
            } catch {
                Log.error("Failed to recover stuck pending actions", category: .sync, error: error)
            }
        }
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

    /// Processes a single pending action.
    func processAction(_ action: PendingAction, context: NSManagedObjectContext) async {
        let objectID = action.objectID
        let actionType = action.actionTypeEnum
        let messageId = action.messageIdValue
        let sourceConversationId = action.conversationIdValue
        let payloadString = action.payloadValue
        let retryCount = action.retryCountValue

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
            await clearLocalModifications(messageId: messageId, payload: payload, context: context)

            Log.info("Processed action: \(type.rawValue) for message: \(messageId ?? "N/A")", category: .sync)

        } catch {
            Log.error("Failed to process action: \(error)", category: .sync)

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
                try? await Task.sleep(nanoseconds: UInt64(min(delay, 30.0) * 1_000_000_000))
            }
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

        // API errors - check specific cases
        if let apiError = error as? APIError {
            switch apiError {
            case .authenticationError, .notFound:
                // 401/403 and 404 - resource doesn't exist or no access, retrying won't help
                return false
            case .rateLimited, .serverError, .networkError, .timeout:
                // Transient errors that may succeed on retry
                return true
            case .invalidURL, .decodingError, .invalidData, .historyIdExpired:
                // These indicate bugs or state issues, not transient failures
                return false
            }
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

    /// Clears local modification flags after successful sync.
    func clearLocalModifications(messageId: String?, payload: [String: Any]?, context: NSManagedObjectContext) async {
        if let messageId = messageId {
            await clearLocalModification(forMessageId: messageId, context: context)
        } else if let messageIds = payload?["messageIds"] as? [String] {
            for msgId in messageIds {
                await clearLocalModification(forMessageId: msgId, context: context)
            }
        }
    }

    /// Clears the localModifiedAt flag for a single message.
    func clearLocalModification(forMessageId messageId: String, context: NSManagedObjectContext) async {
        await context.perform {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageId)

            do {
                if let message = try context.fetch(request).first {
                    message.setValue(nil, forKey: "localModifiedAt")
                    try context.save()
                }
            } catch {
                // Non-critical: local modification flag will be cleared on next sync
                Log.debug("Failed to clear local modification for message \(messageId)", category: .sync)
            }
        }
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
                Log.debug("Cleaned up \(completedActions.count) completed actions", category: .sync)
            } catch {
                // Non-critical: cleanup will happen on next cycle
                Log.debug("Failed to cleanup completed actions", category: .sync)
            }
        }
    }
}
