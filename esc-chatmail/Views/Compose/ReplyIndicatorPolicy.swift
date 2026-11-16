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
    ///   chat's title names someone else, so the row has to name them. So
    ///   does a reply that follows a Reply-To header to an address the
    ///   conversation's rows do not hold. With a
    ///   quote row they go into its label; without one (the quote was
    ///   dropped, which keeps the destination) they get a row of their own.
    ///   Either way they are drawn through `announcedRecipientsText`, which
    ///   keeps a machine's long address from taking the row.
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
        let announced = announcedRecipients ?? []
        guard let replyTarget else {
            // Nothing shares this row, so it names everyone.
            return announcedRecipientsText(announced, limit: nil)
                .map { .addressedTo(label: "To: \($0)") } ?? .none
        }
        return .replyingTo(
            label: replyingToLabel(
                for: replyTarget,
                announcedRecipients: announcedRecipientsText(announced, limit: quoteRowAnnouncedRecipientLimit)
            )
        )
    }

    // MARK: - Announced recipients

    /// The longest an announced address is drawn at. An ordinary address is
    /// shorter and is shown whole; what is longer is nearly always a machine's
    /// (`reply+<60 characters>@reply.github.com`, a help desk's, a mailing
    /// service's), and since a Reply-To reply is announced those are the
    /// common case: a chat with an automated sender whose mail names another
    /// address to answer. At full length one of them took the whole row and
    /// the subject, which says which message the reply quotes, was never seen.
    static let announcedAddressMaxLength = 28

    /// What is kept of the part before the "@" however long the domain is.
    static let announcedAddressMinLocalLength = 3

    /// How many recipients the quote row names before it counts the rest: the
    /// subject follows them on the same line.
    static let quoteRowAnnouncedRecipientLimit = 2

    /// The announced recipients as the row shows them: each address at most
    /// `announcedAddressMaxLength` long (`abbreviatedAddress`) and, where
    /// `limit` is given, the first `limit` of them with the rest counted
    /// ("+2 more"), never silently cut off by the row's end. Nil for none.
    static func announcedRecipientsText(_ recipients: [String], limit: Int?) -> String? {
        guard !recipients.isEmpty else { return nil }
        let named = limit.map { Array(recipients.prefix(max($0, 1))) } ?? recipients
        let text = named.map(abbreviatedAddress).joined(separator: ", ")
        let uncounted = recipients.count - named.count
        return uncounted > 0 ? "\(text) +\(uncounted) more" : text
    }

    /// `address` with the part before the "@" cut to fit
    /// `announcedAddressMaxLength`, or `address` itself where it already fits.
    ///
    /// The domain is never cut, whatever its length: it says whose machine
    /// gets the mail, and the start of a long one can read as somebody else's
    /// (`paypal.com.example.net`).
    static func abbreviatedAddress(_ address: String) -> String {
        guard address.count > announcedAddressMaxLength else { return address }
        guard let at = address.lastIndex(of: "@") else {
            return "\(address.prefix(announcedAddressMaxLength - 1))…"
        }
        let local = address[..<at]
        let domain = address[at...]
        let room = max(announcedAddressMinLocalLength, announcedAddressMaxLength - domain.count - 1)
        guard local.count > room else { return address }
        return "\(local.prefix(room))…\(domain)"
    }

    /// "Replying to:" plus the subject, falling back to the message's preview
    /// text when the subject is blank. Recipients to announce come first,
    /// before the subject: the row is one line and its end is what a narrow
    /// screen cuts off. The caller bounds how much of the line they take
    /// (`announcedRecipientsText`): with one recipient, the usual case, the
    /// subject starts within some 45 characters, which a phone's row has room
    /// for by the size of its caption font (reckoned, not measured on a
    /// device). Two long ones can still push it off a phone.
    static func replyingToLabel(for replyTarget: ReplyTarget, announcedRecipients: String? = nil) -> String {
        let description = [replyTarget.subject, replyTarget.cleanedSnippet, replyTarget.snippet]
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let prefix = announcedRecipients.map { "Replying to \($0):" } ?? "Replying to:"
        return "\(prefix) \(description ?? "(no subject)")"
    }
}
