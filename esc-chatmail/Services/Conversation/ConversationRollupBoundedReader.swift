import Foundation
import CoreData

/// Reads a large conversation's rollup inputs and title senders from the store
/// with bounded queries, instead of walking every message (architecture review
/// 2026-11, data-model#4 and sync-persist-path#2 stage 4; scalability review
/// step 11, `rollup-full-conversation-materialization`). A rollup of a touched
/// 20,000-message chat used to load every row, body text included, with its
/// labels, twice per incremental run.
///
/// The rule stays `ConversationRollupSnapshot.Accumulator`: the store answers
/// for every message it has as saved, and the context's unsaved messages are
/// added from memory. Four things fail silently.
/// - Rollups run before the run's save, over unsaved inserts, label changes,
///   re-homes and deletes. Every stored read leaves out each unsaved message
///   that is or was in the conversation (`Overlay.excludedObjectIDs`, current
///   or last-saved conversation) and does not include pending changes, and
///   those messages still in the conversation are added back from memory. A
///   stored read with pending changes folded in can return the row just
///   archived, which then no longer matches: an inbox conversation with no
///   latest date.
/// - A read that fails throws, and the caller walks the conversation as before.
///   A partial answer is never applied: `hasInbox = false` archives the chat.
/// - The visibility and label spellings are the store's: the visible check is
///   `MessagePredicates.visibleInChat`'s SUBQUERY (`NONE labels` dropped rows
///   with no labels on SQLite) over `chatExcludedLabelIDs`, which must stay the
///   set `MessagePersister.excludedMailboxLabelIDs` names, and the unread count
///   is `MessagePredicates.unreadInInbox`.
/// - The preview can come from an older message than the newest visible one,
///   so it is a walk newest first, a page at a time, that stops at the first
///   message whose `conversationPreviewText` is not blank.
enum ConversationRollupBoundedReader {
    /// A conversation with more stored messages than this is rolled up by
    /// the bounded reader; a smaller one keeps the in-memory walk.
    static let messageCountThreshold = 200

    /// How many visible messages the preview walk reads at a time.
    static let previewPageSize = 16

    /// The context's unsaved messages for one conversation.
    struct Overlay {
        /// Unsaved messages with a stored row that are in the conversation or
        /// were when last saved: the store's answer for them is stale.
        var excludedObjectIDs: [NSManagedObjectID] = []
        /// Unsaved messages in the conversation now, not deleted.
        var messages: [Message] = []
    }

    /// The overlays of every conversation an unsaved message touches. Call on
    /// the context's queue.
    static func overlays(in context: NSManagedObjectContext) -> [NSManagedObjectID: Overlay] {
        var overlays: [NSManagedObjectID: Overlay] = [:]
        let unsaved = context.insertedObjects
            .union(context.updatedObjects)
            .union(context.deletedObjects)
            .compactMap { $0 as? Message }
        for message in unsaved {
            let current = message.isDeleted ? nil : message.conversation?.objectID
            if !message.objectID.isTemporaryID {
                let saved = (message.committedValues(forKeys: ["conversation"])["conversation"] as? Conversation)?.objectID
                for conversationID in Set([current, saved].compactMap { $0 }) {
                    overlays[conversationID, default: Overlay()].excludedObjectIDs.append(message.objectID)
                }
            }
            if let current {
                overlays[current, default: Overlay()].messages.append(message)
            }
        }
        return overlays
    }

    /// Whether the context's store answers the reader's grouped dictionary
    /// fetches: SQLite does, and every production store is SQLite. The
    /// in-memory store most unit tests use raises on them (an Objective-C
    /// exception, not an error a `catch` sees), so a context backed by
    /// anything else, or by a parent context, keeps the walk.
    static func supportsBoundedReads(in context: NSManagedObjectContext) -> Bool {
        guard let stores = context.persistentStoreCoordinator?.persistentStores,
              context.parent == nil,
              !stores.isEmpty else { return false }
        return stores.allSatisfy { $0.type == NSSQLiteStoreType }
    }

    /// The stored message count of each conversation in `conversationIDs`
    /// (permanent IDs) that has stored messages. Call on the context's queue.
    static func storedMessageCounts(
        of conversationIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObjectID: Int] {
        guard !conversationIDs.isEmpty else { return [:] }
        let count = NSExpressionDescription()
        count.name = "messageCount"
        count.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "id")])
        count.expressionResultType = .integer64AttributeType
        let request = NSFetchRequest<NSDictionary>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "conversation IN %@", conversationIDs)
        request.propertiesToGroupBy = ["conversation"]
        request.propertiesToFetch = ["conversation", count]
        var counts: [NSManagedObjectID: Int] = [:]
        for row in try context.fetch(request) {
            guard let conversationID = row["conversation"] as? NSManagedObjectID,
                  let messageCount = (row["messageCount"] as? NSNumber)?.intValue else { continue }
            counts[conversationID] = messageCount
        }
        return counts
    }

    // MARK: - Rollup

    /// The conversation's rollup, read with bounded queries and the overlay.
    /// The conversation's objectID must be permanent. Call on the context's
    /// queue; throws on any failed read, having changed nothing.
    static func snapshot(
        of conversation: Conversation,
        overlay: Overlay?,
        in context: NSManagedObjectContext
    ) throws -> ConversationRollupSnapshot {
        let conversationID = conversation.objectID
        let excluded = overlay?.excludedObjectIDs ?? []
        var accumulator = ConversationRollupSnapshot.Accumulator()

        // Newest visible first, a page at a time, until a message with a
        // preview: the newest is the last-message date, the first with a
        // preview is the snippet.
        var after: ConversationRollupSnapshot.MessageInput?
        pages: while true {
            var predicates = [MessagePredicates.visibleInChat(conversationObjectID: conversationID)]
            if let after {
                predicates.append(NSPredicate(
                    format: "internalDate < %@ OR (internalDate == %@ AND id < %@)",
                    after.internalDate as NSDate,
                    after.internalDate as NSDate,
                    after.id
                ))
            }
            let rows = try storedMessages(
                matching: predicates,
                excluding: excluded,
                limit: previewPageSize,
                in: context
            )
            for row in rows {
                let input = ConversationRollupSnapshot.MessageInput(row)
                if accumulator.latestVisible == nil {
                    accumulator.latestVisible = input
                }
                if MessagePreviewText.nonEmpty(input.previewText) != nil {
                    accumulator.latestVisiblePreview = input
                    break pages
                }
                after = input
            }
            if rows.count < previewPageSize { break }
        }

        accumulator.latestInbox = try storedMessages(
            matching: [NSPredicate(format: "conversation == %@ AND ANY labels.id == %@", conversationID, "INBOX")],
            excluding: excluded,
            limit: 1,
            in: context
        ).first.map(ConversationRollupSnapshot.MessageInput.init)

        let unread = try storedCount(
            matching: MessagePredicates.unreadInInbox(conversationObjectID: conversationID),
            excluding: excluded,
            limit: nil,
            in: context
        )
        accumulator.inboxUnreadCount = Int32(clamping: unread)

        accumulator.hasSentOrFromMeMessages = try storedCount(
            matching: NSPredicate(
                format: "conversation == %@ AND (isFromMe == YES OR ANY labels.id == %@)",
                conversationID,
                "SENT"
            ),
            excluding: excluded,
            limit: 1,
            in: context
        ) > 0

        accumulator.hasReceivedMessages = try storedCount(
            matching: NSPredicate(format: "conversation == %@ AND isFromMe == NO", conversationID),
            excluding: excluded,
            limit: 1,
            in: context
        ) > 0

        for message in overlay?.messages ?? [] {
            accumulator.add(ConversationRollupSnapshot.MessageInput(message))
        }
        return accumulator.snapshot
    }

    /// Stored messages matching every predicate, newest first (then by ID),
    /// leaving out `excluded`, with their labels.
    private static func storedMessages(
        matching predicates: [NSPredicate],
        excluding excluded: [NSManagedObjectID],
        limit: Int,
        in context: NSManagedObjectContext
    ) throws -> [Message] {
        let request = Message.fetchRequest()
        request.predicate = excludingPredicate(predicates, excluded)
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        request.fetchLimit = limit
        request.includesPendingChanges = false
        request.relationshipKeyPathsForPrefetching = ["labels"]
        return try context.fetch(request)
    }

    private static func storedCount(
        matching predicate: NSPredicate,
        excluding excluded: [NSManagedObjectID],
        limit: Int?,
        in context: NSManagedObjectContext
    ) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
        request.predicate = excludingPredicate([predicate], excluded)
        request.includesPendingChanges = false
        if let limit {
            request.fetchLimit = limit
        }
        return try context.count(for: request)
    }

    private static func excludingPredicate(
        _ predicates: [NSPredicate],
        _ excluded: [NSManagedObjectID]
    ) -> NSPredicate {
        var all = predicates
        if !excluded.isEmpty {
            all.append(NSPredicate(format: "NOT (SELF IN %@)", excluded))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: all)
    }

    // MARK: - Title senders

    /// The conversation's senders for its stored title, read from the store
    /// grouped by address and name, with the overlay. Call on the context's
    /// queue; throws on any failed read.
    ///
    /// A name's newest message ID matters only where two names of one address
    /// share their newest date (it orders them), so it is read only for those
    /// dates, and left empty otherwise.
    static func senders(
        of conversation: Conversation,
        overlay: Overlay?,
        in context: NSManagedObjectContext
    ) throws -> ConversationSenderSummary {
        let conversationID = conversation.objectID
        let excluded = overlay?.excludedObjectIDs ?? []
        let base = NSPredicate(format: "conversation == %@ AND senderEmail != nil", conversationID)

        let newestDate = NSExpressionDescription()
        newestDate.name = "newestDate"
        newestDate.expression = NSExpression(forFunction: "max:", arguments: [NSExpression(forKeyPath: "internalDate")])
        newestDate.expressionResultType = .dateAttributeType
        let grouped = NSFetchRequest<NSDictionary>(entityName: "Message")
        grouped.resultType = .dictionaryResultType
        grouped.predicate = excludingPredicate([base], excluded)
        grouped.propertiesToGroupBy = ["senderEmail", "senderName"]
        grouped.propertiesToFetch = ["senderEmail", "senderName", newestDate]

        var stored = ConversationSenderSummary()
        var rawAddresses: [String: Set<String>] = [:]
        for row in try context.fetch(grouped) {
            guard let senderEmail = row["senderEmail"] as? String,
                  let date = row["newestDate"] as? Date else { continue }
            rawAddresses[EmailNormalizer.normalize(senderEmail), default: []].insert(senderEmail)
            stored.add(senderEmail: senderEmail, senderName: row["senderName"] as? String, date: date, id: "")
        }

        let unsaved = ConversationSenderSummary.walking(overlay?.messages ?? [])

        // The dates at which two names of one address tie, with the overlay
        // counted, and the stored names among them.
        var tiedStoredDates: [String: Set<Date>] = [:]
        for email in Set(stored.candidatesByEmail.keys).union(unsaved.candidatesByEmail.keys) {
            let storedNames = stored.candidatesByEmail[email] ?? [:]
            let unsavedNames = unsaved.candidatesByEmail[email] ?? [:]
            var newestByName: [String: Date] = [:]
            for name in Set(storedNames.keys).union(unsavedNames.keys) {
                newestByName[name] = [storedNames[name]?.date, unsavedNames[name]?.date].compactMap { $0 }.max()
            }
            let namesByDate = Dictionary(grouping: newestByName.keys) { newestByName[$0] ?? .distantPast }
            for (date, names) in namesByDate where names.count > 1
                && names.contains(where: { storedNames[$0]?.date == date }) {
                tiedStoredDates[email, default: []].insert(date)
            }
        }

        var result = ConversationSenderSummary()
        result.merge(stored)
        for (email, dates) in tiedStoredDates {
            for date in dates {
                let tied = NSFetchRequest<NSDictionary>(entityName: "Message")
                tied.resultType = .dictionaryResultType
                tied.predicate = excludingPredicate([
                    NSPredicate(format: "conversation == %@", conversationID),
                    NSPredicate(format: "senderEmail IN %@", Array(rawAddresses[email] ?? [])),
                    NSPredicate(format: "internalDate == %@", date as NSDate)
                ], excluded)
                tied.propertiesToFetch = ["senderEmail", "senderName", "id"]
                for row in try context.fetch(tied) {
                    guard let id = row["id"] as? String else { continue }
                    result.add(
                        senderEmail: row["senderEmail"] as? String,
                        senderName: row["senderName"] as? String,
                        date: date,
                        id: id
                    )
                }
            }
        }
        result.merge(unsaved)
        return result
    }
}
