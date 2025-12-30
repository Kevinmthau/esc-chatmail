import Foundation
import Combine

/// Manages recipient list validation, deduplication, and setup for different compose modes
@MainActor
final class RecipientManager: ObservableObject {
    @Published var recipients: [Recipient] = []
    @Published var recipientInput = ""

    private let authSession: AuthSession

    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    func addRecipient(_ recipient: Recipient) {
        guard !recipients.contains(where: { $0.email == recipient.email }) else { return }
        recipients.append(recipient)
    }

    func addRecipient(email: String, displayName: String? = nil) {
        let recipient = Recipient(email: email, displayName: displayName)
        addRecipient(recipient)
    }

    func removeRecipient(_ recipient: Recipient) {
        recipients.removeAll { $0.id == recipient.id }
    }

    func addRecipientFromInput() -> Bool {
        let trimmed = recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, EmailValidator.isValid(trimmed) else { return false }

        let normalized = EmailNormalizer.normalize(trimmed)
        guard !recipients.contains(where: { $0.email == normalized }) else { return false }

        recipients.append(Recipient(email: trimmed))
        recipientInput = ""
        return true
    }

    func setupReplyRecipients(from conversation: Conversation) {
        let currentUserEmail = authSession.userEmail ?? ""
        let participantEmails = Array(conversation.participants ?? [])
            .compactMap { $0.person?.email }
            .filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(currentUserEmail) }

        for email in participantEmails {
            // Try to get display name from person
            if let participant = conversation.participants?.first(where: { $0.person?.email == email }),
               let person = participant.person {
                recipients.append(Recipient(from: person))
            } else {
                recipients.append(Recipient(email: email))
            }
        }
    }

    func clear() {
        recipients.removeAll()
        recipientInput = ""
    }
}
