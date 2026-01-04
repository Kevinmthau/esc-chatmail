import Foundation
import CoreData

// MARK: - Participant Handling

extension MessagePersister {

    /// Saves all participants for a message.
    /// Returns an array of participant emails for avatar prefetching.
    func saveParticipants(
        for processedMessage: ProcessedMessage,
        message: Message,
        in context: NSManagedObjectContext
    ) async -> [String] {
        var participantEmails: [String] = []

        if let from = processedMessage.headers.from {
            await saveParticipant(from: from, kind: .from, for: message, in: context)
            if let email = EmailNormalizer.extractEmail(from: from) {
                participantEmails.append(EmailNormalizer.normalize(email))
            }
        }
        for recipient in processedMessage.headers.to {
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            await saveParticipant(from: headerValue, kind: .to, for: message, in: context)
            participantEmails.append(EmailNormalizer.normalize(recipient.email))
        }
        for recipient in processedMessage.headers.cc {
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            await saveParticipant(from: headerValue, kind: .cc, for: message, in: context)
            participantEmails.append(EmailNormalizer.normalize(recipient.email))
        }
        for recipient in processedMessage.headers.bcc {
            let headerValue = "\(recipient.displayName ?? "") <\(recipient.email)>"
            await saveParticipant(from: headerValue, kind: .bcc, for: message, in: context)
            participantEmails.append(EmailNormalizer.normalize(recipient.email))
        }

        return participantEmails
    }

    /// Saves a single participant using MessageParticipantFactory.
    func saveParticipant(
        from headerValue: String,
        kind: ParticipantKind,
        for message: Message,
        in context: NSManagedObjectContext
    ) async {
        _ = MessageParticipantFactory.create(
            from: headerValue,
            kind: kind,
            for: message,
            in: context
        )
    }
}
