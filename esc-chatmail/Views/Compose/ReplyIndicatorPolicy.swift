import CoreGraphics
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
        ///
        /// `unabridgedLabel` is the label with every announced recipient
        /// named, each address whole; nil where the row announces nobody.
        /// The row is one line, so it draws `label`, and the line's end can
        /// cut even a label that shortens nothing: two addresses of ordinary
        /// length are more than a phone's row holds. So the other label is
        /// carried whenever recipients are announced, the same as `label` or
        /// not. It is what VoiceOver reads, what the Mac shows as the row's
        /// tooltip, and what the iPhone's row draws once the user opens it
        /// (`quoteRow`).
        case replyingTo(label: String, unabridgedLabel: String? = nil)
        /// The reply goes to people the chat's title does not name, and no
        /// quote row is up to say so; no dismiss button, because there is
        /// nothing to drop: the destination is the reply's, not the row's.
        ///
        /// `unabridgedLabel` is the label with each address whole; nil where
        /// `label` already is that. A row that wraps (the bar's) draws it in
        /// place of `label`, on no more lines than fit
        /// `wrappingLabelMaxHeight`.
        case addressedTo(label: String, unabridgedLabel: String? = nil)
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
    ///   keeps a machine's long address from taking the row. They come with
    ///   the people the title does not name first (`recipientsToAnnounce`),
    ///   so the ones the quote row counts and does not name are the chat's
    ///   own people before they are anyone else. What the row shortens or
    ///   counts is still in the header, as its `unabridgedLabel`: a cut
    ///   address can be someone else's, and the row is where the user learns
    ///   who gets the reply. The quote row carries one whenever it announces
    ///   anyone, because its one line can end before the label does.
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
        let everyoneWhole = announced.isEmpty ? nil : announced.joined(separator: ", ")
        guard let replyTarget else {
            // Nothing shares this row, so it names everyone.
            guard let text = announcedRecipientsText(announced, limit: nil) else { return .none }
            let label = "To: \(text)"
            return .addressedTo(
                label: label,
                unabridgedLabel: everyoneWhole.flatMap { unabridged("To: \($0)", beside: label) }
            )
        }
        return .replyingTo(
            label: replyingToLabel(
                for: replyTarget,
                announcedRecipients: announcedRecipientsText(announced, limit: quoteRowAnnouncedRecipientLimit)
            ),
            // Whenever anyone is announced, and not only where `label` cuts
            // or counts: the row's one line can end before the label does.
            unabridgedLabel: everyoneWhole.map { replyingToLabel(for: replyTarget, announcedRecipients: $0) }
        )
    }

    /// A row's label with nothing shortened and nobody only counted: its
    /// `unabridged` one where the header carries one, and `label` itself
    /// where it does not. What a row that wraps draws, and what a one-line
    /// row gives VoiceOver and, on the Mac, its tooltip.
    static func wholeLabel(_ label: String, unabridged: String?) -> String {
        unabridged ?? label
    }

    // MARK: - The whole label on the iPhone

    /// The tallest the text of a header row is drawn (`ChatReplyBarHeaderRow`).
    /// Text that needs more scrolls inside that height.
    ///
    /// A row that wraps draws every announced recipient's address whole, and
    /// both how many there are and how long each is are the sender's to
    /// choose (a Reply-To header). Without a limit the row took the screen:
    /// the composer's height is the transcript's bottom inset, so forty
    /// addresses in the newest message's header left no transcript to read.
    /// Some seven lines of the caption font at its usual size, which is more
    /// than a dozen ordinary addresses.
    static let wrappingLabelMaxHeight: CGFloat = 120

    /// The language tag for text that is in no language (BCP 47 `zxx`), which
    /// is what an address is.
    static let addressLanguageIdentifier = "zxx"

    /// `label` as a row that wraps draws it: the same characters, with each
    /// address marked as text in no language.
    ///
    /// A line that wraps breaks a long word at a syllable and adds a hyphen,
    /// and an address is one long word. `billing@accounts.subsidiary.example.com`
    /// was drawn `billing@accounts.sub-` and, on the next line,
    /// `sidiary.example.com`: a hyphen the address does not have, in the one
    /// row that says who gets the reply, and `sub-sidiary.example.com` is how
    /// another domain is written. Text in no language has no syllables to
    /// break at, so it is broken only where the line runs out, and nothing
    /// is added to it (drawn in the test host, 2026-11-16, iOS 27.0).
    ///
    /// Only the addresses are marked. The label's other words, the subject of
    /// the quoted message among them, keep the language they are in and wrap
    /// as words do.
    ///
    /// An address here is any run of the label between spaces that holds an
    /// "@", with the comma or colon that follows it. A word of a subject that
    /// holds one is marked too, and loses nothing by it.
    static func wrappingLabel(_ label: String) -> AttributedString {
        var result = AttributedString()
        for (index, word) in label.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                result += AttributedString(" ")
            }
            var part = AttributedString(String(word))
            if word.contains("@") {
                part.languageIdentifier = addressLanguageIdentifier
            }
            result += part
        }
        return result
    }

    /// What the iPhone's quote row draws (`ChatReplyBarHeaderRow`).
    struct QuoteRow: Equatable {
        /// The row's text.
        let text: String
        /// Whether the text is on as many lines as it needs, up to
        /// `wrappingLabelMaxHeight`, or on the row's one line.
        let wraps: Bool
        /// Whether a tap on the row opens or closes it, and the row shows the
        /// mark that says so.
        let opens: Bool
    }

    /// The iPhone's quote row, closed or opened by the user.
    ///
    /// Closed it is one line and draws `label`, which can cut an address in
    /// its middle and count recipients it does not name, and whose end the
    /// line can cut again. Two addresses cut that way can be drawn the same,
    /// and before this a sighted user had nowhere to see either whole: the
    /// Mac's row has a tooltip, and VoiceOver is read the whole label. So a
    /// row that announces anyone opens on a tap, and open it draws the
    /// header's unabridged label, wrapped.
    ///
    /// A row that announces nobody carries no unabridged label and does not
    /// open, whatever `isOpen` says: it is the ordinary chat's row, drawn as
    /// it always was.
    static func quoteRow(label: String, unabridgedLabel: String?, isOpen: Bool) -> QuoteRow {
        guard let unabridgedLabel else {
            return QuoteRow(text: label, wraps: false, opens: false)
        }
        return isOpen
            ? QuoteRow(text: unabridgedLabel, wraps: true, opens: true)
            : QuoteRow(text: label, wraps: false, opens: true)
    }

    /// `whole` where the row's `label` says less than it, nil where the two
    /// are the same: a header carries an unabridged label only where there
    /// is more to read than the row draws.
    private static func unabridged(_ whole: String, beside label: String) -> String? {
        whole == label ? nil : whole
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

    /// The most that is kept of the end of the part before the "@". The rest
    /// of what is kept is its start.
    static let announcedAddressLocalTailLength = 4

    /// How many recipients the quote row names before it counts the rest: the
    /// subject follows them on the same line.
    static let quoteRowAnnouncedRecipientLimit = 2

    /// The announced recipients as the row shows them: each address
    /// shortened to `announcedAddressMaxLength` where its domain allows
    /// (`abbreviatedAddress`) and, where `limit` is given, the first `limit`
    /// of them with the rest counted ("+2 more"), never silently cut off by
    /// the row's end. Nil for none.
    ///
    /// The first are the ones named, so the caller's order decides who is
    /// only counted: `ReplyAddressing.recipientsToAnnounce` puts the people
    /// the chat's title does not name first.
    static func announcedRecipientsText(_ recipients: [String], limit: Int?) -> String? {
        guard !recipients.isEmpty else { return nil }
        let named = limit.map { Array(recipients.prefix(max($0, 1))) } ?? recipients
        let text = named.map(abbreviatedAddress).joined(separator: ", ")
        let uncounted = recipients.count - named.count
        return uncounted > 0 ? "\(text) +\(uncounted) more" : text
    }

    /// `address` with the middle of the part before the "@" cut out to fit
    /// `announcedAddressMaxLength`, or `address` itself where it already
    /// fits or the cut would not shorten it.
    ///
    /// The domain is never cut, whatever its length: it says whose machine
    /// gets the mail, and the start of a long one can read as somebody else's
    /// (`paypal.com.example.net`).
    ///
    /// Both ends of the part before the "@" are kept. At a mailbox provider
    /// that part is who gets the mail, and an address made to pass for
    /// another's is most easily made by adding to its end
    /// (`first.last.consulting` and `first.last.consulting.pay`): cut to
    /// their start alone, the two were drawn the same. What is cut is still
    /// lost to the row, which is why the header also carries the label whole
    /// (`Header.replyingTo`).
    static func abbreviatedAddress(_ address: String) -> String {
        guard address.count > announcedAddressMaxLength else { return address }
        guard let at = address.lastIndex(of: "@") else {
            return "\(address.prefix(announcedAddressMaxLength - 1))…"
        }
        let local = address[..<at]
        let domain = address[at...]
        let room = max(announcedAddressMinLocalLength, announcedAddressMaxLength - domain.count - 1)
        // The ellipsis takes a place itself: a part one longer than the room
        // would lose a character and be drawn no shorter.
        guard local.count > room + 1 else { return address }
        let tail = min(announcedAddressLocalTailLength, room / 3)
        return "\(local.prefix(room - tail))…\(local.suffix(tail))\(domain)"
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
