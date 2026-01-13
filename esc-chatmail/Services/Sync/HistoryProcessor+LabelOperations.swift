import Foundation
import CoreData

extension HistoryProcessor {
    /// Maximum age for local modifications before they're considered stale
    /// If a local modification is older than this, we allow server updates
    /// This prevents local changes from blocking server updates indefinitely
    /// Note: 30 minutes allows for slow networks and app suspensions while still
    /// eventually allowing server updates if the pending action truly failed
    static let maxLocalModificationAge: TimeInterval = 1800 // 30 minutes

    func processLabelAdditions(
        _ labelsAdded: [HistoryLabelAdded]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        guard let labelsAdded = labelsAdded else { return }

        var modifiedObjectIDs: [NSManagedObjectID] = []

        for added in labelsAdded {
            let messageId = added.message.id
            let labelIds = added.labelIds
            let hasUnread = labelIds.contains("UNREAD")

            let objectID: NSManagedObjectID? = await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    guard let message = try context.fetch(request).first else {
                        // Message not found locally - this is normal for messages we haven't synced
                        return nil
                    }

                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        Log.debug("Skipping server label addition for message \(messageId) - local changes pending", category: .sync)
                        return nil
                    }

                    // Fetch labels by ID
                    let labelRequest = Label.fetchRequest()
                    labelRequest.predicate = NSPredicate(format: "id IN %@", labelIds)
                    do {
                        let labels = try context.fetch(labelRequest)
                        for label in labels {
                            message.addToLabels(label)
                        }
                        if labels.count != labelIds.count {
                            Log.warning("Only found \(labels.count) of \(labelIds.count) labels for message \(messageId)", category: .sync)
                        }
                    } catch {
                        Log.error("Failed to fetch labels for message \(messageId)", category: .sync, error: error)
                    }

                    if hasUnread {
                        message.isUnread = true
                    }

                    // Return conversation objectID for tracking outside the closure
                    return message.conversation?.objectID
                } catch {
                    Log.error("Failed to fetch message for label addition \(messageId)", category: .sync, error: error)
                    return nil
                }
            }

            if let objectID = objectID {
                modifiedObjectIDs.append(objectID)
            }
        }

        // Track all modified conversations (actor-isolated)
        trackModifiedConversations(modifiedObjectIDs)
    }

    func processLabelRemovals(
        _ labelsRemoved: [HistoryLabelRemoved]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        guard let labelsRemoved = labelsRemoved else { return }

        Log.debug("Processing \(labelsRemoved.count) label removals", category: .sync)

        var modifiedObjectIDs: [NSManagedObjectID] = []

        for removed in labelsRemoved {
            let messageId = removed.message.id
            let labelIds = removed.labelIds
            let removesUnread = labelIds.contains("UNREAD")
            let removesInbox = labelIds.contains("INBOX")

            Log.debug("Label removal: messageId=\(messageId), labels=\(labelIds), removesInbox=\(removesInbox)", category: .sync)

            let objectID: NSManagedObjectID? = await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    guard let message = try context.fetch(request).first else {
                        // Message not found locally - this is normal for messages we haven't synced
                        Log.debug("Message \(messageId) not found locally - skipping", category: .sync)
                        return nil
                    }

                    Log.debug("Found local message \(messageId), applying label removal", category: .sync)

                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        Log.debug("Skipping server label removal for message \(messageId) - local changes pending", category: .sync)
                        return nil
                    }

                    // Fetch labels by ID
                    let labelRequest = Label.fetchRequest()
                    labelRequest.predicate = NSPredicate(format: "id IN %@", labelIds)
                    do {
                        let labels = try context.fetch(labelRequest)
                        for label in labels {
                            message.removeFromLabels(label)
                            Log.debug("Removed label '\(label.id)' from message \(messageId)", category: .sync)
                        }
                    } catch {
                        Log.error("Failed to fetch labels for removal on message \(messageId)", category: .sync, error: error)
                    }

                    if removesUnread {
                        message.isUnread = false
                    }

                    // Return conversation objectID for tracking outside the closure
                    if let conversation = message.conversation {
                        Log.debug("Tracked conversation \(conversation.id.uuidString) for rollup update", category: .sync)
                        return conversation.objectID
                    }
                    return nil
                } catch {
                    Log.error("Failed to fetch message for label removal \(messageId)", category: .sync, error: error)
                    return nil
                }
            }

            if let objectID = objectID {
                modifiedObjectIDs.append(objectID)
            }
        }

        // Track all modified conversations (actor-isolated)
        trackModifiedConversations(modifiedObjectIDs)
    }

    /// Check if a message has local modifications that haven't been synced yet
    nonisolated func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
        guard let syncStartTime = syncStartTime else { return false }
        guard let localModifiedAt = message.localModifiedAtValue else { return false }

        // If the message was modified locally after the sync started,
        // it means there's a pending local change that should take precedence
        let hasPendingChange = localModifiedAt > syncStartTime

        // However, if the local modification is too old, consider it stale
        // This prevents local changes from blocking server updates indefinitely
        // This can happen if the action failed to sync to the server
        let now = Date()
        let modificationAge = now.timeIntervalSince(localModifiedAt)
        let isStaleModification = modificationAge > Self.maxLocalModificationAge

        if hasPendingChange && isStaleModification {
            Log.warning("Local modification is stale (age: \(Int(modificationAge))s), allowing server update", category: .sync)
            return false
        }

        return hasPendingChange
    }
}
