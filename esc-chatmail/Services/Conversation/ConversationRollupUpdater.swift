import Foundation
import CoreData

/// Handles updating conversation rollup data (lastMessageDate, snippet, hasInbox, etc.)
/// Extracted from ConversationManager for focused responsibility.
/// Struct is naturally Sendable since it only holds immutable references.
struct ConversationRollupUpdater: Sendable {
    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Single Conversation Rollup

    /// Updates rollup data for a conversation. Must be called from within the conversation's context queue.
    /// - Parameters:
    ///   - conversation: The conversation to update
    ///   - myEmail: The current user's email (must be captured before entering context.perform block)
    func updateRollups(for conversation: Conversation, myEmail: String) {
        guard conversation.managedObjectContext != nil else { return }
        let messages = conversation.messages ?? []
        let snapshot = ConversationRollupSnapshot.make(from: messages)
        logRollupSnapshot(snapshot, for: conversation, totalCount: messages.count)
        snapshot.apply(to: conversation)

        updateDisplayNameOnly(for: conversation, myEmail: myEmail)
    }

    // MARK: - Batch Rollup Operations

    /// Updates rollups for ALL conversations - expensive O(n*m) operation.
    /// Prefer updateRollupsForModified when possible.
    @MainActor
    func updateAllRollups(
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50
            // Prefetch relationships to avoid N+1 queries when accessing messages/labels/participants
            request.relationshipKeyPathsForPrefetching = [
                "messages",
                "messages.labels",
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch conversations for rollup update", category: .conversation, error: error)
                return
            }

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
            }
        }
    }

    /// Updates rollups only for conversations that were modified.
    /// Much more efficient than updateAllRollups - O(k*m) where k << n.
    @MainActor
    func updateRollupsForModified(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        guard !conversationIDs.isEmpty else { return }

        await context.perform {
            // Use batch fetch with prefetching instead of individual existingObject calls
            // This avoids N+1 queries when accessing messages/labels/participants
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "SELF IN %@", conversationIDs)
            request.relationshipKeyPathsForPrefetching = [
                "messages",
                "messages.labels",
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to batch fetch conversations for rollup update", category: .conversation, error: error)
                return
            }

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
            }
        }
    }

    /// Updates rollups for conversations by keyHash.
    @MainActor
    func updateRollupsForConversations(
        keyHashes: Set<String>,
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        guard !keyHashes.isEmpty else { return }

        await context.perform {
            let request = Conversation.fetchRequest()
            request.predicate = ConversationPredicates.keyHashes(Array(keyHashes))
            request.fetchBatchSize = 50
            // Prefetch relationships to avoid N+1 queries when accessing messages/labels/participants
            request.relationshipKeyPathsForPrefetching = [
                "messages",
                "messages.labels",
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch conversations by keyHash for rollup update", category: .conversation, error: error)
                return
            }

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
            }
        }
    }

    /// Refreshes stored conversation display names without recomputing any other rollup fields.
    @MainActor
    func updateDisplayNamesForAllConversations(
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50
            request.relationshipKeyPathsForPrefetching = [
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch conversations for display-name refresh", category: .conversation, error: error)
                return
            }

            for conversation in conversations {
                self.updateDisplayNameOnly(for: conversation, myEmail: myEmail)
            }
        }
    }

    // MARK: - Private Helper Methods

    private func logRollupSnapshot(
        _ snapshot: ConversationRollupSnapshot,
        for conversation: Conversation,
        totalCount: Int
    ) {
        Log.diagnostic(
            .conversationRollups,
            "Conversation \(conversation.id.uuidString): hasInbox=\(snapshot.hasInbox), unread=\(snapshot.inboxUnreadCount), totalMsgCount=\(totalCount), hidden=\(conversation.hidden)",
            category: .conversation
        )
    }

    /// Updates only the stored display name from participants, excluding the current user.
    func updateDisplayNameOnly(for conversation: Conversation, myEmail: String) {
        guard let participants = conversation.participants else { return }

        let normalizedMyEmail = EmailNormalizer.normalize(myEmail)

        // Log all participants for debugging
        let allParticipantEmails = participants.compactMap { $0.person?.email }
        Log.diagnostic(
            .conversationRollups,
            "Conversation \(conversation.id): All participants: \(allParticipantEmails)",
            category: .conversation
        )
        Log.diagnostic(
            .conversationRollups,
            "My email: \(myEmail) (normalized: \(normalizedMyEmail))",
            category: .conversation
        )

        // Deduplicate participants by normalized email
        var seenEmails = Set<String>()
        var names: [String] = []

        for participant in participants {
            guard let person = participant.person else { continue }
            if EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                Log.diagnostic(
                    .conversationRollups,
                    "Excluding Hide My Email relay participant: \(person.email)",
                    category: .conversation
                )
                continue
            }
            let email = person.email
            let normalizedEmail = EmailNormalizer.normalize(email)

            // Exclude current user from display name
            if normalizedEmail == normalizedMyEmail {
                Log.diagnostic(.conversationRollups, "Excluding self: \(email)", category: .conversation)
                continue
            }

            // Skip duplicates
            guard !seenEmails.contains(normalizedEmail) else { continue }
            seenEmails.insert(normalizedEmail)

            // Use displayName, fall back to formatted email, fall back to "Unknown"
            let name: String
            if let displayName = person.displayName, !displayName.isEmpty {
                name = displayName
            } else if !email.isEmpty {
                name = EmailNormalizer.formatAsDisplayName(email: email)
            } else {
                name = "Unknown"
            }
            Log.diagnostic(.conversationRollups, "Including participant: \(name)", category: .conversation)
            names.append(name)
        }

        let finalDisplayName = DisplayNameFormatter.formatGroupNames(names)
        Log.diagnostic(
            .conversationRollups,
            "Final displayName: \(finalDisplayName), snippet: \(conversation.snippet ?? "nil")",
            category: .conversation
        )
        // Ensure we never set an empty display name
        let resolvedDisplayName = finalDisplayName.isEmpty ? "Unknown" : finalDisplayName
        guard conversation.displayName != resolvedDisplayName else { return }
        conversation.displayName = resolvedDisplayName
    }
}
