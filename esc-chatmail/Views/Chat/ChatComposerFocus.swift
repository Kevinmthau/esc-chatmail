import SwiftUI

/// Whether a chat's reply field has the keyboard focus, and the way to give or take it,
/// whichever kind of field the chat's composer draws.
///
/// The iPhone's field is a SwiftUI `TextField` bound to the chat's `FocusState`. The Mac's is an
/// `NSTextView` (`MacReplyTextField`), which `FocusState` does not reach, so it reports through
/// a `ReplyFieldFocusBridge`. A chat has one field or the other, and everything that asks
/// "is the composer focused" or dismisses the keyboard goes through `wrappedValue`, spelled as
/// a `FocusState` binding's is, so those call sites read the same for both.
@MainActor
struct ChatComposerFocus {
    /// The SwiftUI field's focus: what `ChatReplyBar` binds the iPhone's field to.
    let fieldBinding: FocusState<Bool>.Binding
    /// The AppKit field's focus. The chat that owns it observes it, so a change re-evaluates
    /// the chat as a `FocusState` change does.
    let bridge: ReplyFieldFocusBridge

    var wrappedValue: Bool {
        get { fieldBinding.wrappedValue || bridge.isFocused }
        nonmutating set {
            fieldBinding.wrappedValue = newValue
            bridge.requestFocus(newValue)
        }
    }
}
