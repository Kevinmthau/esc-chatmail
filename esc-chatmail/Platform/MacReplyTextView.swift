#if os(macOS)
import AppKit

/// The text view inside the Mac's reply field (`MacReplyTextField`).
///
/// A subclass only to report what a delegate is not told: that it gained or lost the keyboard
/// focus, and that it entered or left a window. The field's keys are decided by its delegate
/// (`MacReplyTextFieldCoordinator`, `ReplyFieldKeyPolicy`).
final class MacReplyTextView: NSTextView {
    /// The view became (`true`) or stopped being (`false`) its window's first responder.
    var onFocusChange: ((Bool) -> Void)?
    /// The view entered a window (`true`) or left one (`false`).
    var onWindowChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onFocusChange?(false) }
        return didResign
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }
}
#endif
