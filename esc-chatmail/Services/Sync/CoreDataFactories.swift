import Foundation
import CoreData

// MARK: - Person Factory

/// Factory for creating and finding Person entities
/// Centralizes Person creation logic for reuse across services
///
/// Lookups go through a context-scoped `[normalized email: Person]` cache in
/// `context.userInfo` (precedent: InlineCIDAttachmentPrefetchScheduler), so a
/// batch `prefetch` turns the per-participant find-or-create fetches into
/// dictionary hits. Hits are validated against the context — rollback and
/// reset deregister objects without touching userInfo — and store-teardown
/// paths must call `resetCache(in:)` (destroying the store invalidates
/// registered objects in a way per-hit validation cannot see). All entry
/// points must be called on the context's queue (inside `perform`), which is
/// also what `context.fetch` already required.
struct PersonFactory {

    private static let cacheUserInfoKey = "PersonFactory.personsByEmail"

    private static func cache(in context: NSManagedObjectContext) -> NSMutableDictionary {
        if let existing = context.userInfo[cacheUserInfoKey] as? NSMutableDictionary {
            return existing
        }
        let fresh = NSMutableDictionary()
        context.userInfo[cacheUserInfoKey] = fresh
        return fresh
    }

    private static func validCachedPerson(
        forEmail email: String,
        in cache: NSMutableDictionary,
        context: NSManagedObjectContext
    ) -> Person? {
        guard let person = cache[email] as? Person else { return nil }
        // A hit is only trustworthy while the instance is still registered
        // with this context: rollback() discards unsaved inserts and reset()
        // deregisters everything, both without touching userInfo. Returning
        // a stale entry would hand callers an unfulfillable fault to wire
        // into new relationships (or crash faulting its properties).
        guard person.managedObjectContext === context, !person.isDeleted else {
            cache.removeObject(forKey: email)
            return nil
        }
        return person
    }

    /// Drops the context's person cache wholesale. Store-teardown paths must
    /// call this (CoreDataStack.resetStore does): destroying the backing
    /// store invalidates every registered object without deregistering it,
    /// so the per-hit staleness check cannot detect those zombies.
    static func resetCache(in context: NSManagedObjectContext) {
        context.userInfo.removeObject(forKey: cacheUserInfoKey)
    }

    private static func fetchPerson(email: String, in context: NSManagedObjectContext) -> Person? {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", email)
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        return try? context.fetch(request).first
    }

    /// Finds an existing person by email or creates a new one.
    /// The email is normalized so cache keys and Person rows stay consistent
    /// regardless of caller (live callers already pass normalized emails).
    /// - Throws: CoreDataError.entityCreationFailed if entity creation fails
    static func findOrCreate(
        email rawEmail: String,
        displayName: String?,
        in context: NSManagedObjectContext
    ) throws -> Person {
        let email = EmailNormalizer.normalize(rawEmail)
        let cache = cache(in: context)

        let existing = validCachedPerson(forEmail: email, in: cache, context: context) ?? {
            let fetched = fetchPerson(email: email, in: context)
            if let fetched {
                cache[email] = fetched
            }
            return fetched
        }()

        if let existing {
            // Update display name if the new one is better for this email —
            // on cache hits too, so batches keep improving names.
            if EmailNormalizer.isBetterDisplayName(displayName, than: existing.displayName, forEmail: email) {
                existing.displayName = displayName
                PersonDisplayInfoChangeNotification.invalidatePersonCacheAndPostLater(emails: [email])
            }
            return existing
        }

        guard let person = NSEntityDescription.insertNewObject(forEntityName: "Person", into: context) as? Person else {
            throw CoreDataError.entityCreationFailed("Person")
        }
        person.id = UUID()
        person.email = email
        person.displayName = displayName
        cache[email] = person
        return person
    }

    /// Cache-aware lookup that never creates. Returns nil when no Person row
    /// exists for the (normalized) email.
    static func lookup(email rawEmail: String, in context: NSManagedObjectContext) -> Person? {
        let email = EmailNormalizer.normalize(rawEmail)
        let cache = cache(in: context)
        if let cached = validCachedPerson(forEmail: email, in: cache, context: context) {
            return cached
        }
        guard let fetched = fetchPerson(email: email, in: context) else { return nil }
        cache[email] = fetched
        return fetched
    }

    /// Batch-fetches persons by email and primes the context cache so the
    /// per-participant lookups in a save batch stop hitting SQLite (N+1).
    @discardableResult
    static func prefetch(emails: [String], in context: NSManagedObjectContext) -> [String: Person] {
        let normalized = Set(emails.map(EmailNormalizer.normalize)).filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [:] }

        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email IN %@", Array(normalized))
        request.fetchBatchSize = 100

        guard let persons = try? context.fetch(request) else { return [:] }

        // Duplicate-email Person rows are legal (Person.email has no
        // uniqueness constraint), so collapse duplicates instead of trapping;
        // findOrCreate's fetchLimit-1 lookup is equally arbitrary about which
        // duplicate wins.
        let byEmail = Dictionary(persons.map { ($0.email, $0) }, uniquingKeysWith: { first, _ in first })

        let cache = cache(in: context)
        for (email, person) in byEmail {
            cache[email] = person
        }
        return byEmail
    }
}

// MARK: - Conversation Factory

/// Factory for creating Conversation and ConversationParticipant entities
struct ConversationFactory {

    /// Creates a new conversation with the given identity
    /// - Parameters:
    ///   - identity: The conversation identity containing participants and type
    ///   - initialLastMessageDate: Optional date to set as lastMessageDate immediately (prevents UI flash where conversation appears at bottom)
    ///   - context: The Core Data context to create the conversation in
    /// - Throws: CoreDataError.entityCreationFailed if entity creation fails
    static func create(
        for identity: ConversationIdentity,
        initialLastMessageDate: Date? = nil,
        in context: NSManagedObjectContext
    ) throws -> Conversation {
        guard let conversation = NSEntityDescription.insertNewObject(
            forEntityName: "Conversation",
            into: context
        ) as? Conversation else {
            throw CoreDataError.entityCreationFailed("Conversation")
        }
        conversation.id = UUID()
        conversation.keyHash = identity.keyHash
        conversation.participantHash = identity.participantHash
        conversation.conversationType = identity.type
        // New conversations start as active (not archived)
        conversation.archivedAt = nil
        // Set initial lastMessageDate if provided (ensures conversation sorts correctly before message is fully saved)
        conversation.lastMessageDate = initialLastMessageDate

        // Create participants with display names from email headers
        for email in identity.participants {
            let displayName = identity.participantDisplayNames[email]
            let person = try PersonFactory.findOrCreate(email: email, displayName: displayName, in: context)
            try createParticipant(person: person, conversation: conversation, role: .normal, in: context)
        }

        return conversation
    }

    /// Creates a conversation participant
    /// - Throws: CoreDataError.entityCreationFailed if entity creation fails
    static func createParticipant(
        person: Person,
        conversation: Conversation,
        role: ParticipantRole,
        in context: NSManagedObjectContext
    ) throws {
        guard let participant = NSEntityDescription.insertNewObject(
            forEntityName: "ConversationParticipant",
            into: context
        ) as? ConversationParticipant else {
            throw CoreDataError.entityCreationFailed("ConversationParticipant")
        }
        participant.id = UUID()
        participant.participantRole = role
        participant.person = person
        participant.conversation = conversation
    }
}

// MARK: - Message Participant Factory

/// Factory for creating MessageParticipant entities
struct MessageParticipantFactory {

    /// Creates a message participant from a header value
    /// Returns nil if email extraction fails, throws if entity creation fails
    static func create(
        from headerValue: String,
        kind: ParticipantKind,
        for message: Message,
        in context: NSManagedObjectContext
    ) throws -> MessageParticipant? {
        guard let email = EmailNormalizer.extractEmail(from: headerValue) else { return nil }

        let normalizedEmail = EmailNormalizer.normalize(email)
        let displayName = EmailNormalizer.extractDisplayName(from: headerValue)

        let person = try PersonFactory.findOrCreate(
            email: normalizedEmail,
            displayName: displayName,
            in: context
        )

        guard let participant = NSEntityDescription.insertNewObject(
            forEntityName: "MessageParticipant",
            into: context
        ) as? MessageParticipant else {
            throw CoreDataError.entityCreationFailed("MessageParticipant")
        }
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message

        return participant
    }
}

// MARK: - Attachment Factory

/// Factory for creating Attachment entities
struct AttachmentFactory {

    /// Creates an attachment from attachment info
    /// - Throws: CoreDataError.entityCreationFailed if entity creation fails
    static func create(
        from info: AttachmentInfo,
        for message: Message,
        in context: NSManagedObjectContext
    ) throws -> Attachment {
        guard let attachment = NSEntityDescription.insertNewObject(
            forEntityName: "Attachment",
            into: context
        ) as? Attachment else {
            throw CoreDataError.entityCreationFailed("Attachment")
        }
        attachment.setValue(info.id, forKey: "id")
        attachment.setValue(info.contentId, forKey: "contentId")
        attachment.setValue(info.filename, forKey: "filename")
        attachment.setValue(info.mimeType, forKey: "mimeType")
        attachment.setValue(Int64(info.size), forKey: "byteSize")
        attachment.setValue("queued", forKey: "stateRaw")
        attachment.setValue(message, forKey: "message")
        return attachment
    }
}
