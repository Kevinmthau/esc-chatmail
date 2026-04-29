import Foundation
import CoreData

// MARK: - Person Factory

/// Factory for creating and finding Person entities
/// Centralizes Person creation logic for reuse across services
struct PersonFactory {

    /// Finds an existing person by email or creates a new one
    /// - Throws: CoreDataError.entityCreationFailed if entity creation fails
    static func findOrCreate(
        email: String,
        displayName: String?,
        in context: NSManagedObjectContext
    ) throws -> Person {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", email)
        request.fetchLimit = 1
        request.fetchBatchSize = 1

        if let existing = try? context.fetch(request).first {
            // Update display name if the new one is better for this email.
            if EmailNormalizer.isBetterDisplayName(displayName, than: existing.displayName, forEmail: email) {
                existing.displayName = displayName
            }
            return existing
        }

        guard let person = NSEntityDescription.insertNewObject(forEntityName: "Person", into: context) as? Person else {
            throw CoreDataError.entityCreationFailed("Person")
        }
        person.id = UUID()
        person.email = email
        person.displayName = displayName
        return person
    }

    /// Batch prefetch persons by email for efficient lookups
    static func prefetch(emails: [String], in context: NSManagedObjectContext) -> [String: Person] {
        guard !emails.isEmpty else { return [:] }

        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email IN %@", emails)
        request.fetchBatchSize = 100

        guard let persons = try? context.fetch(request) else { return [:] }

        return Dictionary(uniqueKeysWithValues: persons.map { ($0.email, $0) })
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
