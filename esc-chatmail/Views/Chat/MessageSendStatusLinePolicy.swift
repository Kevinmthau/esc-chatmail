import Foundation

/// The send-status caption that leads an outgoing bubble's timestamp ("Sent · 2:41 PM").
///
/// It shares the timestamp's line instead of taking a row of its own. The old standalone status
/// row grew every reply bubble by ~17pt from its first frame and removed itself, unanimated, the
/// moment Gmail answered, so the bubble shrank and the transcript dropped. On the timestamp line a
/// status change never changes the row's height, so every transition can simply crossfade. The
/// one exception is accessibility text sizes (`Arrangement.stacked`).
enum MessageSendStatusLinePolicy {
    enum Line: Equatable {
        case sending
        /// Gmail accepted the newest row; shown only under the conversation's newest message.
        case sent
        case notSent
        case deliveryUnknown
        case sendFailed

        var label: String {
            switch self {
            case .sending:
                return "Sending…"
            case .sent:
                return "Sent"
            case .notSent:
                return MessageSendStatusPresentation.notSent.label ?? "Not sent"
            case .deliveryUnknown:
                return MessageSendStatusPresentation.deliveryUnknown.label ?? "Delivery unknown"
            case .sendFailed:
                return MessageSendStatusPresentation.sendFailed.label ?? "Send failed"
            }
        }
    }

    /// Where the caption sits relative to the timestamp.
    enum Arrangement: Equatable {
        /// One line, caption first: "Sent · 2:41 PM". First, because the outgoing column is
        /// trailing-aligned and the line's width follows the caption ("Sending…" is wider than
        /// "Sent", and no caption is narrower still). With the caption after the timestamp, every
        /// change slid "2:41 PM" sideways mid-crossfade. Ahead of it, the timestamp keeps its
        /// trailing edge and only the caption's leading side moves.
        case inline
        /// Accessibility text sizes: the caption on its own line above the timestamp. Inline, the
        /// 280pt column truncated the caption ("Delivery unkn…") and could wrap the timestamp,
        /// so a receipt arriving or leaving changed the row's height anyway. Stacked, the height
        /// changes only when a caption appears or leaves, and only at these sizes.
        case stacked
    }

    static func arrangement(isAccessibilityTextSize: Bool) -> Arrangement {
        isAccessibilityTextSize ? .stacked : .inline
    }

    /// How long a send must stay pending before "Sending…" shows. Gmail usually accepts a reply
    /// within it, so a fast send goes straight to "Sent" instead of flashing "Sending…" on and off.
    static let sendingRevealDelay: TimeInterval = 0.7

    /// The caption for a row, or nil for none.
    ///
    /// - Parameters:
    ///   - presentation: the row's durable status (`MessageSendStatusPresentation.resolve`).
    ///   - isSendingRevealDue: whether the row has been pending for `sendingRevealDelay`.
    ///   - isConfirmedInGmail: `ChatMessageRowModel.isConfirmedInGmail`, the positive evidence
    ///     "Sent" requires.
    ///   - isNewestInTranscript: whether the row is the conversation's newest message
    ///     (`newestRowIndex`). Like iMessage's receipt, "Sent" lives only there and leaves the
    ///     row when a newer message arrives.
    static func line(
        presentation: MessageSendStatusPresentation,
        isSendingRevealDue: Bool,
        isFromMe: Bool,
        isConfirmedInGmail: Bool,
        isNewestInTranscript: Bool
    ) -> Line? {
        switch presentation {
        case .notSent:
            return .notSent
        case .deliveryUnknown:
            // Never "Sent": Gmail may or may not have this reply.
            return .deliveryUnknown
        case .sendFailed:
            return .sendFailed
        case .sending:
            return isSendingRevealDue ? .sending : nil
        case .none:
            // `.none` alone is not evidence: the row mapper also falls back to it when an
            // optimistic row's record fetch fails or finds nothing, and that row may really be
            // "Delivery unknown" or "Not sent". "Sent" therefore requires `isConfirmedInGmail`:
            // an optimistic row whose record carries Gmail's committed IDs (it renders as sent
            // while sync persists the echo), or a row sync brought from Gmail. A synced row proves
            // Gmail holds the message, not that it went out: the chat excludes only DRAFT, SPAM
            // and TRASH, so a reply scheduled in Gmail's web client can sync in as an own row
            // before its send time and, as the newest row, read "Sent" early. The row model
            // carries no labels to tell it apart.
            return isFromMe && isConfirmedInGmail && isNewestInTranscript ? .sent : nil
        }
    }

    /// Remaining wait before a send pending since `pendingSince` shows "Sending…", in
    /// `0...sendingRevealDelay`. Anchored on the optimistic row's `internalDate` (stamped when the
    /// send began) rather than on when the row's view appeared, so a row the lazy transcript
    /// rebuilds mid-send — scrolled away and back — does not restart the grace period.
    static func remainingSendingRevealDelay(pendingSince: Date, now: Date) -> TimeInterval {
        let elapsed = now.timeIntervalSince(pendingSince)
        return min(sendingRevealDelay, max(0, sendingRevealDelay - elapsed))
    }

    /// Index, within the displayed rows, of the conversation's newest message: the last row,
    /// but only when the window shows the latest messages. Any other window has none on screen.
    static func newestRowIndex(displayedRowCount: Int, isShowingLatestWindow: Bool) -> Int? {
        guard isShowingLatestWindow, displayedRowCount > 0 else { return nil }
        return displayedRowCount - 1
    }
}
