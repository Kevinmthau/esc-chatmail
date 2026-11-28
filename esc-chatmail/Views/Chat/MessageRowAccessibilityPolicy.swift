import Foundation

/// What VoiceOver is told of a transcript row before its content (architecture review 2026-11,
/// gap-accessibility-architecture#1): who wrote it, its send state where it has one, and when.
///
/// The bubble's column is one element (`MessageBubble`), whose own label is its children's
/// text: the subject, the attachments' names, the bubble's text or card. This is said before
/// that, and it never holds content: a label rebuilt from the row model's text would re-derive
/// what the bubble's routing and the stored verdict decide, and read stripped links, card text
/// or the loading pill wrongly. Direction shows only in layout and color otherwise, and a
/// mid-run row of a one-to-one chat (every row on the Mac) has no avatar or name at all.
enum MessageRowAccessibilityPolicy {
    /// "You" for the user's own message; else the sender as the row knows them, the loaded
    /// name first, then the header's display name, then the address; nil where it knows
    /// nothing.
    static func speaker(
        isFromMe: Bool,
        loadedSenderName: String?,
        headerSenderName: String?,
        senderEmail: String?
    ) -> String? {
        if isFromMe { return "You" }
        return [loadedSenderName, headerSenderName, senderEmail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// The label said before the row's content: the speaker, the send-status line's label
    /// where the row shows one ("Not sent", "Delivery unknown"), and the time, joined with
    /// commas.
    static func labelPrefix(speaker: String?, statusLabel: String?, time: String) -> String {
        [speaker, statusLabel, time]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
