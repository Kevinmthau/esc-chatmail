import Foundation
import CoreData

// MARK: - Generic Fetch Helpers

extension NSManagedObjectContext {

    /// Fetches the first entity matching the predicate
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to fetch
    ///   - predicate: Optional predicate to filter results
    ///   - sortDescriptors: Optional sort descriptors
    /// - Returns: The first matching entity, or nil if none found
    func fetchFirst<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor]? = nil
    ) throws -> T? {
        let request = T.fetchRequest()
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        request.fetchLimit = 1
        return try fetch(request).first as? T
    }

    /// Fetches all entities matching the predicate
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to fetch
    ///   - predicate: Optional predicate to filter results
    ///   - sortDescriptors: Optional sort descriptors
    ///   - limit: Optional fetch limit
    /// - Returns: Array of matching entities
    func fetchAll<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor]? = nil,
        limit: Int? = nil
    ) throws -> [T] {
        let request = T.fetchRequest()
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        if let limit = limit {
            request.fetchLimit = limit
        }
        return try fetch(request) as? [T] ?? []
    }

    /// Counts entities matching the predicate
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to count
    ///   - predicate: Optional predicate to filter
    /// - Returns: Count of matching entities
    func count<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil
    ) throws -> Int {
        let request = T.fetchRequest()
        request.predicate = predicate
        return try count(for: request)
    }

    /// Checks if any entity matches the predicate
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to check
    ///   - predicate: Optional predicate to filter
    /// - Returns: true if at least one entity matches
    func exists<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil
    ) throws -> Bool {
        try count(type, where: predicate) > 0
    }

    /// Fetches dictionary results for lightweight queries
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to query
    ///   - properties: Property names to fetch
    ///   - predicate: Optional predicate to filter
    ///   - sortDescriptors: Optional sort descriptors
    /// - Returns: Array of dictionaries with requested properties
    func fetchDictionary<T: NSManagedObject>(
        _ type: T.Type,
        properties: [String],
        where predicate: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor]? = nil
    ) throws -> [[String: Any]] {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: type))
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = properties
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return try fetch(request) as? [[String: Any]] ?? []
    }
}

// MARK: - Entity-Specific Fetch Helpers

extension NSManagedObjectContext {

    // MARK: Message

    /// Fetches a Message by its Gmail ID
    func fetchMessage(byId id: String) throws -> Message? {
        try fetchFirst(Message.self, where: MessagePredicates.id(id))
    }

    /// Fetches multiple Messages by their Gmail IDs
    func fetchMessages(byIds ids: [String]) throws -> [Message] {
        guard !ids.isEmpty else { return [] }
        return try fetchAll(Message.self, where: MessagePredicates.ids(ids))
    }

    /// Fetches Messages for a conversation
    func fetchMessages(forConversation conversation: Conversation, sortedByDate ascending: Bool = true) throws -> [Message] {
        try fetchAll(
            Message.self,
            where: MessagePredicates.inConversation(conversation),
            sortedBy: [NSSortDescriptor(key: "internalDate", ascending: ascending)]
        )
    }

    // MARK: Conversation

    /// Fetches a Conversation by its UUID
    func fetchConversation(byId id: UUID) throws -> Conversation? {
        try fetchFirst(Conversation.self, where: ConversationPredicates.id(id))
    }

    /// Fetches a Conversation by its keyHash
    func fetchConversation(byKeyHash keyHash: String) throws -> Conversation? {
        try fetchFirst(Conversation.self, where: ConversationPredicates.keyHash(keyHash))
    }

    /// Fetches active (non-archived) Conversations by participantHash
    func fetchActiveConversation(byParticipantHash hash: String) throws -> Conversation? {
        try fetchFirst(Conversation.self, where: ConversationPredicates.activeWithParticipantHash(hash))
    }

    // MARK: Person

    /// Fetches a Person by email
    func fetchPerson(byEmail email: String) throws -> Person? {
        try fetchFirst(Person.self, where: PersonPredicates.email(email))
    }

    /// Fetches multiple Persons by emails
    func fetchPersons(byEmails emails: [String]) throws -> [Person] {
        guard !emails.isEmpty else { return [] }
        return try fetchAll(Person.self, where: PersonPredicates.emails(emails))
    }

    // MARK: Label

    /// Fetches a Label by its Gmail ID
    func fetchLabel(byId id: String) throws -> Label? {
        try fetchFirst(Label.self, where: LabelPredicates.id(id))
    }

    /// Fetches multiple Labels by their IDs
    func fetchLabels(byIds ids: [String]) throws -> [Label] {
        guard !ids.isEmpty else { return [] }
        return try fetchAll(Label.self, where: LabelPredicates.ids(ids))
    }

    // MARK: PendingAction

    /// Fetches pending actions ready for processing
    func fetchPendingActions(limit: Int? = nil) throws -> [PendingAction] {
        try fetchAll(
            PendingAction.self,
            where: PendingActionPredicates.pendingOrFailed,
            sortedBy: [NSSortDescriptor(key: "createdAt", ascending: true)],
            limit: limit
        )
    }

    /// Fetches the next pending action to process
    func fetchNextPendingAction(maxRetries: Int) throws -> PendingAction? {
        try fetchFirst(
            PendingAction.self,
            where: PendingActionPredicates.readyToProcess(maxRetries: maxRetries),
            sortedBy: [NSSortDescriptor(key: "createdAt", ascending: true)]
        )
    }

    // MARK: Account

    /// Fetches the first Account (typically there's only one)
    func fetchAccount() throws -> Account? {
        try fetchFirst(Account.self)
    }
}

// MARK: - Predicate Builders

/// Type-safe predicates for Message entity
enum MessagePredicates {
    static func id(_ id: String) -> NSPredicate {
        NSPredicate(format: "id == %@", id)
    }

    static func ids(_ ids: [String]) -> NSPredicate {
        NSPredicate(format: "id IN %@", ids)
    }

    static func threadId(_ threadId: String) -> NSPredicate {
        NSPredicate(format: "gmThreadId == %@", threadId)
    }

    static func inConversation(_ conversation: Conversation) -> NSPredicate {
        NSPredicate(format: "conversation == %@", conversation)
    }

    static func hasLabel(_ labelId: String) -> NSPredicate {
        NSPredicate(format: "ANY labels.id == %@", labelId)
    }

    static func notHavingLabel(_ labelId: String) -> NSPredicate {
        NSPredicate(format: "NONE labels.id == %@", labelId)
    }

    static let unread = NSPredicate(format: "isUnread == YES")
    static let read = NSPredicate(format: "isUnread == NO")
    static let inbox = hasLabel("INBOX")
    static let drafts = hasLabel("DRAFTS")
    static let excludingDrafts = notHavingLabel("DRAFTS")

    static func olderThan(_ date: Date) -> NSPredicate {
        NSPredicate(format: "internalDate < %@", date as CVarArg)
    }
}

/// Type-safe predicates for Conversation entity
enum ConversationPredicates {
    static func id(_ id: UUID) -> NSPredicate {
        NSPredicate(format: "id == %@", id as CVarArg)
    }

    static func keyHash(_ hash: String) -> NSPredicate {
        NSPredicate(format: "keyHash == %@", hash)
    }

    static func participantHash(_ hash: String) -> NSPredicate {
        NSPredicate(format: "participantHash == %@", hash)
    }

    static func activeWithParticipantHash(_ hash: String) -> NSPredicate {
        NSPredicate(format: "participantHash == %@ AND archivedAt == nil", hash)
    }

    static let active = NSPredicate(format: "archivedAt == nil")
    static let archived = NSPredicate(format: "archivedAt != nil")
    static let hasInbox = NSPredicate(format: "hasInbox == YES")
    static let hidden = NSPredicate(format: "hidden == YES")
    static let visible = NSPredicate(format: "hidden == NO")

    static func keyHashes(_ hashes: [String]) -> NSPredicate {
        NSPredicate(format: "keyHash IN %@", hashes)
    }

    static let empty = NSPredicate(format: "messages.@count == 0 AND participants.@count == 0")
    static let emptyMessages = NSPredicate(format: "messages.@count == 0")
}

/// Type-safe predicates for Person entity
enum PersonPredicates {
    static func email(_ email: String) -> NSPredicate {
        NSPredicate(format: "email == %@", email)
    }

    static func emails(_ emails: [String]) -> NSPredicate {
        NSPredicate(format: "email IN %@", emails)
    }

    static func emailContains(_ substring: String) -> NSPredicate {
        NSPredicate(format: "email CONTAINS[cd] %@", substring)
    }
}

/// Type-safe predicates for Label entity
enum LabelPredicates {
    static func id(_ id: String) -> NSPredicate {
        NSPredicate(format: "id == %@", id)
    }

    static func ids(_ ids: [String]) -> NSPredicate {
        NSPredicate(format: "id IN %@", ids)
    }

    static func name(_ name: String) -> NSPredicate {
        NSPredicate(format: "name == %@", name)
    }
}

/// Type-safe predicates for PendingAction entity
enum PendingActionPredicates {
    static func id(_ id: UUID) -> NSPredicate {
        NSPredicate(format: "id == %@", id as CVarArg)
    }

    static func messageId(_ messageId: String) -> NSPredicate {
        NSPredicate(format: "messageId == %@", messageId)
    }

    static let pending = NSPredicate(format: "status == %@", "pending")
    static let failed = NSPredicate(format: "status == %@", "failed")
    static let completed = NSPredicate(format: "status == %@", "completed")
    static let pendingOrFailed = NSPredicate(format: "status == %@ OR status == %@", "pending", "failed")

    static func readyToProcess(maxRetries: Int) -> NSPredicate {
        NSPredicate(format: "status == %@ OR (status == %@ AND retryCount < %d)", "pending", "failed", maxRetries)
    }
}

/// Type-safe predicates for Attachment entity
enum AttachmentPredicates {
    static func id(_ id: String) -> NSPredicate {
        NSPredicate(format: "id == %@", id)
    }

    static func messageId(_ messageId: String) -> NSPredicate {
        NSPredicate(format: "messageId == %@", messageId)
    }

    static let orphaned = NSPredicate(format: "message == nil")
}
