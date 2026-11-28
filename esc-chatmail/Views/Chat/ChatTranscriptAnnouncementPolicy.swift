import Foundation

/// What the open chat announces to VoiceOver, and when (architecture review 2026-11,
/// gap-accessibility-architecture#2). Two events, both of which a sighted reader sees and a
/// VoiceOver user heard nothing of: mail arriving at the bottom of the open chat, which is
/// marked read in Gmail as it lays out there; and a reply of theirs becoming Not sent,
/// Delivery unknown or Send failed.
///
/// Built from the row models' values in the turn they change, never from a body file, and
/// never logged. Names and states only, no content: an announcement is spoken aloud, and the
/// message itself is a row the user can move to.
enum ChatTranscriptAnnouncementPolicy {
    /// The least time between two arrival announcements. A sync that lands a burst over
    /// several saves would otherwise speak over itself; an arrival within it is not announced
    /// on its own, and is in the transcript to move to.
    static let minimumArrivalAnnouncementSpacing: TimeInterval = 3

    /// The announcement for `rows`, the messages just marked read on arrival, or nil for
    /// none. The user's own rows are left out (their echo is never unread, so the chat does
    /// not mark it, and an optimistic send is not an arrival).
    static func arrivalAnnouncement(rows: [ChatMessageRowModel]) -> String? {
        let arrivals = rows.filter { !$0.isFromMe }
        guard !arrivals.isEmpty else { return nil }
        let senders = arrivals.map(senderName(of:))
        // One sender's name, where every arrival has the same one.
        let sender = senders.allSatisfy { $0 == senders[0] } ? senders[0] : nil
        if arrivals.count == 1 {
            return sender.map { "New message from \($0)" } ?? "New message"
        }
        return sender.map { "\(arrivals.count) new messages from \($0)" } ?? "\(arrivals.count) new messages"
    }

    /// Whether an arrival announcement may be spoken at `now`, after the last one at
    /// `lastAnnouncedAt` (nil for none yet).
    static func allowsArrivalAnnouncement(at now: TimeInterval, lastAnnouncedAt: TimeInterval?) -> Bool {
        guard let lastAnnouncedAt else { return true }
        return now - lastAnnouncedAt >= minimumArrivalAnnouncementSpacing
    }

    /// The send status of each of the user's own displayed rows that has one, keyed by the
    /// row's display identity: an optimistic reply and its echo share one, so the echo
    /// replacing the reply is a row whose status left `.sending` for none, never a new row. A
    /// row with no status is left out, which is also what the mapper's fallback to `.none`
    /// reads as.
    static func ownSendStatuses(
        rows: [ChatMessageRowModel]
    ) -> [ChatMessageDisplayIdentity: MessageSendStatusPresentation] {
        var statuses: [ChatMessageDisplayIdentity: MessageSendStatusPresentation] = [:]
        for row in rows where row.isFromMe {
            let status = MessageSendStatusPresentation.resolve(
                deliveryState: row.outboundSendDeliveryState,
                isSendingLocalAttachments: row.isSendingLocalAttachments,
                hasFailedLocalAttachmentUploads: row.hasFailedLocalAttachmentUploads
            )
            if status != .none {
                statuses[row.displayIdentity] = status
            }
        }
        return statuses
    }

    /// One announcement for each row whose status left `.sending` for a failed or uncertain
    /// one, between two readings of `ownSendStatuses`. Nothing for a row that arrived already
    /// failed (a window load, a chat opened on a failed reply), and nothing for `.sending`
    /// ending with no status (the send was accepted and its echo replaced it).
    static func sendOutcomeAnnouncements(
        old: [ChatMessageDisplayIdentity: MessageSendStatusPresentation],
        new: [ChatMessageDisplayIdentity: MessageSendStatusPresentation]
    ) -> [String] {
        new.compactMap { identity, status -> (ChatMessageDisplayIdentity, String)? in
            guard old[identity] == .sending, let text = sendOutcomeText(status) else { return nil }
            return (identity, text)
        }
        .sorted { String(describing: $0.0) < String(describing: $1.0) }
        .map(\.1)
    }

    private static func sendOutcomeText(_ status: MessageSendStatusPresentation) -> String? {
        switch status {
        case .notSent:
            return "Your message was not sent"
        case .deliveryUnknown:
            return "Delivery of your message is unknown"
        case .sendFailed:
            return "Your message failed to send"
        case .none, .sending:
            return nil
        }
    }

    private static func senderName(of row: ChatMessageRowModel) -> String? {
        [row.senderName, row.effectiveSenderEmail, row.senderEmail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
