import Foundation

/// Formats quoted text for forwards and replies
@MainActor
struct MessageFormatBuilder {
    let authSession: AuthSession

    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    /// Result of formatting a forwarded message
    struct ForwardResult {
        let body: String
        let subject: String?
    }

    func formatForwardedMessage(_ message: Message) -> ForwardResult {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var quotedText = "\n\n---------- Forwarded message ---------\n"

        // Get sender info
        let participants = Array(message.conversation?.participants ?? [])

        if message.isFromMe {
            quotedText += "From: \(authSession.userEmail ?? "Me")\n"
        } else {
            if let otherParticipant = participants.first(where: { participant in
                let email = participant.person?.email ?? ""
                return EmailNormalizer.normalize(email) != EmailNormalizer.normalize(authSession.userEmail ?? "")
            })?.person {
                quotedText += "From: \(otherParticipant.name ?? otherParticipant.email)\n"
            }
        }

        quotedText += "Date: \(formatter.string(from: message.internalDate))\n"

        var subject: String?
        if let originalSubject = message.subject, !originalSubject.isEmpty {
            quotedText += "Subject: \(originalSubject)\n"

            // Set subject with Fwd: prefix
            if originalSubject.lowercased().hasPrefix("fwd:") || originalSubject.lowercased().hasPrefix("fw:") {
                subject = originalSubject
            } else {
                subject = "Fwd: \(originalSubject)"
            }
        }

        let recipientList = participants.compactMap { $0.person?.email }
            .filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(authSession.userEmail ?? "") }

        if !recipientList.isEmpty {
            quotedText += "To: \(recipientList.joined(separator: ", "))\n"
        }

        quotedText += "\n"

        if let snippet = message.snippet {
            quotedText += snippet
        }

        return ForwardResult(body: quotedText, subject: subject)
    }
}
