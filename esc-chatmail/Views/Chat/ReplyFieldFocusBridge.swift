import Combine
import Foundation

/// The keyboard focus of a reply field that SwiftUI's `FocusState` does not reach: the Mac's
/// `NSTextView` field (`MacReplyTextField`), which takes and gives up the focus as AppKit's
/// first responder.
///
/// The field reports here when it gains or loses the focus, and takes requests from here to
/// gain or give it up. A chat reads and writes both this and its `FocusState` through one
/// `ChatComposerFocus`. On iOS no field ever attaches, so `isFocused` stays false and a
/// request does nothing.
///
/// It carries one request that is not about the focus, because it is the composer's only way
/// to the field: `commitPendingInput`, made by the send arrow before it sends.
///
/// The chat observes this, so a report publishes, and a publish must not land inside a SwiftUI
/// update. AppKit tells a text view it lost the focus while SwiftUI is taking the view out of
/// its window, so the field reports on the next turn of the run loop
/// (`MacReplyTextFieldCoordinator`); nothing here defers anything.
@MainActor
final class ReplyFieldFocusBridge: ObservableObject {
    /// Whether the attached field is the window's first responder.
    @Published private(set) var isFocused = false

    /// The field that is attached, and so the only one whose `detach` counts.
    private var attachedField: ObjectIdentifier?
    /// Asks the attached field to take (`true`) or give up (`false`) the focus. Nil until a
    /// field attaches.
    private var applyFocus: ((Bool) -> Void)?
    /// A request made while no field was attached. A chat asks for the focus as it appears,
    /// before its field is in a window; the field takes it when it attaches.
    private var pendingRequest: Bool?
    /// Asks the attached field to commit the word an input method is still composing. Nil
    /// until a field attaches.
    private var commitFieldInput: (() -> Void)?

    /// The chat asks for the field to take or give up the focus.
    func requestFocus(_ wantsFocus: Bool) {
        if let applyFocus {
            applyFocus(wantsFocus)
        } else {
            pendingRequest = wantsFocus
        }
    }

    /// The composer is about to read the field's text from outside the field (the send
    /// arrow): the field commits the word an input method is still composing, so the
    /// composer's copy holds it. Return in the field needs no such request; the field decides
    /// that key itself (`ReplyFieldKeyPolicy`). Nothing to do with no field attached.
    func commitPendingInput() {
        commitFieldInput?()
    }

    /// `field` is in a window and can take the focus. A request made before now is applied.
    func attach(
        field: AnyObject,
        applyFocus: @escaping (Bool) -> Void,
        commitPendingInput: @escaping () -> Void = {}
    ) {
        attachedField = ObjectIdentifier(field)
        self.applyFocus = applyFocus
        commitFieldInput = commitPendingInput
        if let pendingRequest {
            self.pendingRequest = nil
            applyFocus(pendingRequest)
        }
    }

    /// `field` left its window. If it is the attached field, the chat's field no longer has the
    /// focus and takes no requests.
    ///
    /// A field tells the bridge it left a turn of the run loop after it did, and by then the
    /// chat may have built another field that attached in its place. A detach from the field
    /// that is gone must not take the new one's place away.
    func detach(field: AnyObject) {
        guard attachedField == ObjectIdentifier(field) else { return }
        attachedField = nil
        applyFocus = nil
        commitFieldInput = nil
        fieldDidChangeFocus(false)
    }

    /// The field gained or lost the focus.
    func fieldDidChangeFocus(_ isFocused: Bool) {
        // Not republished unchanged: a publish re-evaluates the chat that observes this.
        guard self.isFocused != isFocused else { return }
        self.isFocused = isFocused
    }
}
