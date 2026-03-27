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
}
