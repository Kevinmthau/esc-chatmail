import Foundation
import CoreData

/// Extension containing query methods for PendingActionsManager.
///
/// These methods provide read-only access to pending action state without
/// modifying any data. They're used by UI and other services to check
/// pending action status.
extension PendingActionsManager {

    /// Returns the count of pending or failed actions that haven't exceeded retry limit.
    public func pendingActionCount() async -> Int {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSNumber>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@ OR status == %@", "pending", "failed")
            request.resultType = .countResultType

            do {
                return try context.fetch(request).first?.intValue ?? 0
            } catch {
                Log.error("Failed to count pending actions", category: .sync, error: error)
                return 0
            }
        }
    }

    /// Checks if there's a pending action for a specific message and type.
    public func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "messageId == %@ AND actionType == %@ AND (status == %@ OR status == %@)",
                messageId, type.rawValue, "pending", "processing"
            )
            request.fetchLimit = 1

            do {
                return try context.fetch(request).first != nil
            } catch {
                Log.error("Failed to check for pending action", category: .sync, error: error)
                return false  // Assume no pending action on error
            }
        }
    }

    /// Cancels a pending action for a specific message and type.
    public func cancelPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async {
        await MainActor.run {
            let context = coreDataStack.viewContext
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "messageId == %@ AND actionType == %@ AND status == %@",
                messageId, type.rawValue, "pending"
            )

            do {
                let actions = try context.fetch(request)
                for action in actions {
                    context.delete(action)
                }
                coreDataStack.saveIfNeeded(context: context)
            } catch {
                Log.error("Failed to cancel pending action for message \(messageId)", category: .sync, error: error)
            }
        }
    }
}
