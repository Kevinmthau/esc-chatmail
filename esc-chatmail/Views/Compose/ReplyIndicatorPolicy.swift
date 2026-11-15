import Foundation

/// Pure display-decision namespace for the header row `ChatReplyBar` shows
/// above its text field, per the house convention that view decisions live in
/// `enum XPolicy` static-function namespaces (see `MessageDisplayPolicy`).
enum ReplyIndicatorPolicy {
    /// The text fields of the message being replied to that can label it.
    struct ReplyTarget: Equatable {
        let subject: String?
        let cleanedSnippet: String?
        let snippet: String?
    }

    enum Header: Equatable {
        /// The draft's target is gone; the row offers "Clear target".
        case unavailableTarget
        /// A recovered failed reply owns the destination; no dismiss button.
        case recoveredEnvelope(label: String)
        /// The dismissible "Replying to:" row. Its X drops the quote.
        case replyingTo(label: String)
        /// The reply goes to people the chat's title does not name, and no
        /// quote row is up to say so; no dismiss button, because there is
        /// nothing to drop: the destination is the reply's, not the row's.
        case addressedTo(label: String)
        case none
    }

    /// - Parameter announcedRecipients: The reply's recipients where they are
    ///   not the conversation's own people (`ReplyAddressing.recipientsToAnnounce`),
    ///   nil where they are. A chat merged while a contact card linked two
    ///   addresses keeps both people's mail after the card stops linking them,
    ///   and a reply to the other person's message goes to that person: the
    ///   chat's title names someone else, so the row has to name them. With a
    ///   quote row they go into its label; without one (the quote was
    ///   dropped, which keeps the destination) they get a row of their own.
    static func header(
        isReplyTargetUnavailable: Bool,
        recoveredRecipients: [String]?,
        replyTarget: ReplyTarget?,
        announcedRecipients: [String]? = nil
    ) -> Header {
        if isReplyTargetUnavailable {
            return .unavailableTarget
        }
        if let recoveredRecipients {
            return .recoveredEnvelope(
                label: "Replying to: \(recoveredRecipients.joined(separator: ", "))"
            )
        }
        // The quote is sent whenever a target exists
        // (`includesQuotedMessage: replyingTo != nil`), so the dismissible row
        // must show whenever one exists. Gating it on a non-empty subject hid
        // the only way to drop the quote of a subjectless message.
        let announced = announcedRecipients.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }
        guard let replyTarget else {
            return announced.map { .addressedTo(label: "To: \($0)") } ?? .none
        }
        return .replyingTo(label: replyingToLabel(for: replyTarget, announcedRecipients: announced))
    }

    /// "Replying to:" plus the subject, falling back to the message's preview
    /// text when the subject is blank. Recipients to announce come first,
    /// before the subject: the row is one line and its end is what a narrow
    /// screen cuts off.
    static func replyingToLabel(for replyTarget: ReplyTarget, announcedRecipients: String? = nil) -> String {
        let description = [replyTarget.subject, replyTarget.cleanedSnippet, replyTarget.snippet]
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let prefix = announcedRecipients.map { "Replying to \($0):" } ?? "Replying to:"
        return "\(prefix) \(description ?? "(no subject)")"
    }
}
