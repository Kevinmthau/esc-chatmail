import Foundation

/// The words on a message field, per the house convention that view decisions live in pure
/// `enum XPolicy` namespaces.
///
/// One definition for every field a message's text is typed in: the chat's reply field on iOS
/// and on the Mac (`ChatReplyBar`), the New Message sheet's (`ComposeInputBar`) and the body of
/// the compose sheet that has a Subject field (`ComposeView`). Each of them used to write out
/// its own word: three said "iMessage" and the last said "Message", and the change to "Email"
/// reached only the three.
enum MessageFieldPolicy {
    /// What an empty message field shows.
    ///
    /// It is also the field's name for VoiceOver and Voice Control (`PlaceholderTextField`,
    /// `MacChatReplyBarLayout`): the drawn word is hidden from accessibility and the field
    /// carries it, so a field is asked for by the word the user sees in it.
    static let placeholder = "Email"

    /// What the empty body of the compose sheet that has a Subject field shows. A forward's
    /// message is a note above the forwarded email and may be left empty, so its field says
    /// that in place of the word.
    static func composeBodyPlaceholder(isForward: Bool) -> String {
        isForward ? "Add a message (optional)" : placeholder
    }
}
