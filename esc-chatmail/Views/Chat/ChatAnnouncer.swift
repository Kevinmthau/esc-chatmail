import SwiftUI

/// Speaks the open chat's announcements to VoiceOver (`ChatTranscriptAnnouncementPolicy`;
/// architecture review 2026-11, gap-accessibility-architecture#2). One for the chat's life,
/// made with its coordinator: it holds the arrival announcements' spacing, so the coordinator
/// keeps no state of its own for them.
///
/// It posts through `post`, `AccessibilityNotification.Announcement` in the app, which
/// VoiceOver speaks and which does nothing while VoiceOver is off, on iOS and the Mac alike.
/// Tests record instead. Nothing here reads a body file or logs a text.
@MainActor
final class ChatAnnouncer {
    private let post: @MainActor (String) -> Void
    private let now: () -> TimeInterval
    private var lastArrivalAnnouncementAt: TimeInterval?

    init(
        post: @escaping @MainActor (String) -> Void = { text in
            AccessibilityNotification.Announcement(text).post()
        },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.post = post
        self.now = now
    }

    /// Announces `rows`, the messages the chat has just marked read on arrival, unless the
    /// last arrival announcement was too recent
    /// (`ChatTranscriptAnnouncementPolicy.minimumArrivalAnnouncementSpacing`).
    func announceArrivals(_ rows: [ChatMessageRowModel]) {
        guard let text = ChatTranscriptAnnouncementPolicy.arrivalAnnouncement(rows: rows) else {
            return
        }
        let now = now()
        guard ChatTranscriptAnnouncementPolicy.allowsArrivalAnnouncement(
            at: now,
            lastAnnouncedAt: lastArrivalAnnouncementAt
        ) else {
            return
        }
        lastArrivalAnnouncementAt = now
        post(text)
    }

    /// Announces each of the user's replies that became Not sent, Delivery unknown or Send
    /// failed between two readings of `ChatTranscriptAnnouncementPolicy.ownSendStatuses`.
    func announceSendOutcomes(
        old: [ChatMessageDisplayIdentity: MessageSendStatusPresentation],
        new: [ChatMessageDisplayIdentity: MessageSendStatusPresentation]
    ) {
        for text in ChatTranscriptAnnouncementPolicy.sendOutcomeAnnouncements(old: old, new: new) {
            post(text)
        }
    }
}
