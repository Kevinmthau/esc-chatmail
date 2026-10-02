import Foundation

/// Which reply-bar controls stay live while a send owns the composer.
///
/// `isSending` now lasts only from the tap until the optimistic message is
/// durable, and the composer is already empty by then.
enum ChatReplyBarControlPolicy {
    /// The text field never disables. The whole bar used to be
    /// `.disabled(isSending)`, and SwiftUI takes focus from a disabled field:
    /// the keyboard dropped on every send, the transcript re-anchored two or
    /// three times while the bubble animated in, keystrokes during the send
    /// were lost, and every follow-up needed another tap on the field.
    static func isTextFieldEnabled(isSending _: Bool) -> Bool {
        true
    }

    /// Controls that change the draft's attachments or destination wait for
    /// the release. `removeAttachment` deletes files the send's MIME build may
    /// still read, and a target change would race the snapshot restore.
    static func allowsDraftMutation(isSending: Bool) -> Bool {
        !isSending
    }

    /// The optimistic bubble already shows its own sending indicator, so the
    /// send button does not swap to a spinner (iMessage shows none).
    static let sendButtonShowsProgress = false
}
