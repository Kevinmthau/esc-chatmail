import Foundation

/// What each `ChatComposerStyle` draws and does, per the house convention that view decisions
/// live in pure `enum XPolicy` namespaces (`docs/mac-imessage-ui-plan.md`, PR 5).
enum ChatComposerPolicy {
    /// What is drawn behind the composer's controls.
    enum Backdrop: Equatable {
        /// A divider over an opaque bar: nothing of the transcript shows under the composer.
        case dividerOverOpaqueBar
        /// No divider and no bar. The transcript scrolls under the composer and fades out
        /// towards the window's bottom edge, so a row passing under the controls does not
        /// read as part of them.
        case fade
    }

    static func backdrop(for style: ChatComposerStyle) -> Backdrop {
        switch style {
        case .bar: return .dividerOverOpaqueBar
        case .floating: return .fade
        }
    }

    /// The floating composer's sizes; nil for the bar, which draws at the iPhone's own.
    static func floatingMetrics(for style: ChatComposerStyle) -> ChatComposerMetrics? {
        switch style {
        case .bar: return nil
        case .floating(let metrics): return metrics
        }
    }

    /// Whether the floating composer shows its send arrow.
    ///
    /// Only while there is something to send (decision 2 of the plan): Messages on the Mac has
    /// no send button, but without one there is no way to send with the mouse, and nowhere to
    /// show that a send is waiting on an attachment. Whether the arrow is *enabled* is
    /// `ChatReplyBar.canSend`'s to say, the same check Return asks.
    static func showsSendArrow(replyText: String, hasAttachments: Bool) -> Bool {
        // The composer's own rule for "there is a draft", which the draft store shares.
        ChatComposerState.hasDraftContent(replyText: replyText, hasAttachments: hasAttachments)
    }

    /// What made a chat appear: how its row came to be selected.
    enum AppearanceTrigger: Equatable {
        /// A key was the event being handled: an arrow key in the sidebar, or Delete archiving
        /// the row before this one.
        case keyPress
        /// Anything else: a click on the row, a menu command, a swipe.
        case other
    }

    /// Whether a chat puts the caret in its reply field when it appears.
    ///
    /// On the Mac, selecting a conversation does, as in Messages, so the user can type at
    /// once. Not when a key selected it: the sidebar's list is then what the user is driving,
    /// and taking the focus from it would stop the arrow keys after one row and send the next
    /// Delete to an empty field instead of archiving the next conversation
    /// (`MacMailboxView`'s batch actions). Never on iOS, where focusing the field raises the
    /// keyboard over the chat the user just opened to read.
    static func focusesFieldWhenChatAppears(
        style: ChatComposerStyle,
        trigger: AppearanceTrigger
    ) -> Bool {
        switch style {
        case .bar: return false
        case .floating: return trigger != .keyPress
        }
    }

    /// Whether Escape in the reply field drops the quoted message, as the indicator's X does.
    ///
    /// Only the dismissible "Replying to" row: a recovered envelope has no dismiss button, and
    /// an unavailable target is cleared by its own button, which says what it does. Not while
    /// a send owns the draft (`ChatReplyBarControlPolicy.allowsDraftMutation`).
    static func escapeDropsQuote(
        header: ReplyIndicatorPolicy.Header,
        allowsDraftMutation: Bool
    ) -> Bool {
        guard allowsDraftMutation else { return false }
        if case .replyingTo = header { return true }
        return false
    }
}
