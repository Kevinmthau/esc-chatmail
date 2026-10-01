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
        case none
    }

    static func header(
        isReplyTargetUnavailable: Bool,
        recoveredRecipients: [String]?,
        replyTarget: ReplyTarget?
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
        guard let replyTarget else { return .none }
        return .replyingTo(label: replyingToLabel(for: replyTarget))
    }

    /// "Replying to:" plus the subject, falling back to the message's preview
    /// text when the subject is blank.
    static func replyingToLabel(for replyTarget: ReplyTarget) -> String {
        let description = [replyTarget.subject, replyTarget.cleanedSnippet, replyTarget.snippet]
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return "Replying to: \(description ?? "(no subject)")"
    }
}
