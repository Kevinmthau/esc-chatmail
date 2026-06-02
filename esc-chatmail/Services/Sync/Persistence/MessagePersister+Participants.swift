import Foundation
import CoreData

// MARK: - Participant Handling

extension MessagePersister {

    /// Saves all participants for a message.
    /// Returns an array of participant emails for avatar prefetching.
    nonisolated func saveParticipants(
        for processedMessage: ProcessedMessage,
        message: Message,
        in context: NSManagedObjectContext
    ) -> [String] {
        var participantEmails: [String] = []

        if let from = processedMessage.headers.from {
            saveParticipant(from: from, kind: .from, for: message, in: context)
            if let email = EmailNormalizer.extractEmail(from: from) {
                participantEmails.append(EmailNormalizer.normalize(email))
            }
        }
        for recipient in processedMessage.headers.to {
            if EmailNormalizer.isHideMyEmailDisplayName(recipient.displayName) {
                continue
            }
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            saveParticipant(from: headerValue, kind: .to, for: message, in: context)
            participantEmails.append(EmailNormalizer.normalize(recipient.email))
        }
        for recipient in processedMessage.headers.cc {
            if EmailNormalizer.isHideMyEmailDisplayName(recipient.displayName) {
                continue
            }
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            saveParticipant(from: headerValue, kind: .cc, for: message, in: context)
            participantEmails.append(EmailNormalizer.normalize(recipient.email))
        }
        for recipient in processedMessage.headers.bcc {
            if EmailNormalizer.isHideMyEmailDisplayName(recipient.displayName) {
                continue
            }
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            saveParticipant(from: headerValue, kind: .bcc, for: message, in: context)
            participantEmails.append(EmailNormalizer.normalize(recipient.email))
        }

        return participantEmails
    }

    /// Saves a single participant using MessageParticipantFactory.
    nonisolated func saveParticipant(
        from headerValue: String,
        kind: ParticipantKind,
        for message: Message,
        in context: NSManagedObjectContext
    ) {
        do {
            _ = try MessageParticipantFactory.create(
                from: headerValue,
                kind: kind,
                for: message,
                in: context
            )
        } catch {
            Log.error("Failed to create participant for message \(message.id): \(error)", category: .coreData)
        }
    }

    /// Enriches existing participant Person records with better display names from refreshed headers.
    /// Existing messages are updated without recreating MessageParticipant rows, so this keeps
    /// conversation titles aligned with the latest `From` / recipient header names.
    nonisolated func updateKnownParticipantDisplayNames(
        from headers: ProcessedHeaders,
        in context: NSManagedObjectContext
    ) -> (emails: [String], conversationIDs: Set<NSManagedObjectID>) {
        var invalidatedEmails = Set<String>()
        var invalidatedConversationIDs = Set<NSManagedObjectID>()

        func update(email rawEmail: String, displayName rawDisplayName: String?) {
            let displayName = rawDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let displayName,
                  !displayName.isEmpty,
                  !EmailNormalizer.isHideMyEmailDisplayName(displayName) else {
                return
            }

            let email = EmailNormalizer.normalize(rawEmail)
            guard !email.isEmpty else { return }

            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            request.fetchLimit = 1
            request.fetchBatchSize = 1

            do {
                guard let person = try context.fetch(request).first,
                      EmailNormalizer.isBetterDisplayName(displayName, than: person.displayName, forEmail: email),
                      person.displayName != displayName else {
                    return
                }

                person.displayName = displayName
                invalidatedEmails.insert(email)
                for participation in person.conversationParticipations ?? [] {
                    if let conversationID = participation.conversation?.objectID {
                        invalidatedConversationIDs.insert(conversationID)
                    }
                }
            } catch {
                Log.error("Failed to update participant display name for \(Log.redact(email: email))", category: .coreData, error: error)
            }
        }

        if let from = headers.from,
           let email = EmailNormalizer.extractEmail(from: from) {
            update(
                email: email,
                displayName: EmailNormalizer.extractDisplayName(from: from)
            )
        }

        for recipient in headers.to + headers.cc + headers.bcc {
            update(email: recipient.email, displayName: recipient.displayName)
        }

        return (Array(invalidatedEmails), invalidatedConversationIDs)
    }
}
