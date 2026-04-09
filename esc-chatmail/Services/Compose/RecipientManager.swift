import Foundation
import Combine

/// Manages recipient list validation, deduplication, and setup for different compose modes
@MainActor
final class RecipientManager: ObservableObject {
    @Published var recipients: [Recipient] = []
    @Published var recipientInput = ""

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

    func setupRecipients(_ recipients: [Recipient]) {
        for recipient in recipients {
            addRecipient(recipient)
        }
    }

    func clear() {
        recipients.removeAll()
        recipientInput = ""
    }
}
