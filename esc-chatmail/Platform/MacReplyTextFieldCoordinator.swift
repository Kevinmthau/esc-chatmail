#if os(macOS)
import AppKit

/// The delegate of the Mac reply field's text view (`MacReplyTextField`): it carries the text to
/// the composer, decides the field's keys through `ReplyFieldKeyPolicy`, measures the field's
/// height, and connects the view's focus to the chat's `ReplyFieldFocusBridge`.
@MainActor
final class MacReplyTextFieldCoordinator: NSObject, NSTextViewDelegate {
    /// The field as SwiftUI last described it. Replaced on every update, so the closures read
    /// here are the current ones.
    var field: MacReplyTextField
    private(set) weak var textView: MacReplyTextView?
    /// SwiftUI has taken the field apart (`dismantleNSView`).
    private var isDismantled = false

    /// A second text layout, used only to measure: the height of a string at a width, without
    /// touching the layout the view draws from.
    private let measuringStorage = NSTextStorage()
    private let measuringLayoutManager = NSLayoutManager()
    private let measuringContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )

    init(field: MacReplyTextField) {
        self.field = field
        super.init()
        measuringContainer.lineFragmentPadding = 0
        measuringLayoutManager.addTextContainer(measuringContainer)
        measuringStorage.addLayoutManager(measuringLayoutManager)
    }

    var font: NSFont {
        NSFont.systemFont(ofSize: field.fontSize)
    }

    // MARK: - Setup

    func attach(_ textView: MacReplyTextView) {
        self.textView = textView
        textView.delegate = self
        let bridge = field.focusBridge
        textView.onFocusChange = { [weak bridge] isFocused in
            // On the next turn of the run loop: the chat observes the bridge, and AppKit says
            // "you lost the focus" while SwiftUI is taking this view out of its window, which
            // is inside a SwiftUI update, where nothing may publish.
            DispatchQueue.main.async {
                bridge?.fieldDidChangeFocus(isFocused)
            }
        }
        textView.onWindowChange = { [weak self, weak bridge] isInWindow in
            guard let self, let bridge else { return }
            if isInWindow {
                // Publishes nothing, so it is done now: a request the chat made before the
                // field existed is waiting for it.
                bridge.attach(field: self) { [weak self] wantsFocus in self?.applyFocus(wantsFocus) }
            } else {
                self.detachFromBridgeSoon()
            }
        }
    }

    func detach() {
        isDismantled = true
        textView?.onFocusChange = nil
        textView?.onWindowChange = nil
        textView?.delegate = nil
        detachFromBridgeSoon()
    }

    /// Tells the bridge this field is gone, on the next turn of the run loop, for the reason
    /// its focus reports wait a turn. If the view is back in a window by then, it is not gone.
    private func detachFromBridgeSoon() {
        let bridge = field.focusBridge
        DispatchQueue.main.async { [self] in
            guard isDismantled || textView?.window == nil else { return }
            bridge.detach(field: self)
        }
    }

    /// Gives the view the focus, or takes it away if the view has it.
    ///
    /// On the next turn of the run loop, not now. The first request usually arrives as the
    /// view enters its window, which is while the window is still putting the chat's views in
    /// place, and often inside the click on the sidebar's row that selected the chat: the list
    /// takes the focus for that click, and the field has to take it after.
    private func applyFocus(_ wantsFocus: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.textView, let window = textView.window else { return }
            if wantsFocus {
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            } else if window.firstResponder === textView {
                // Only if the field has it: a request to drop the focus must not take it from
                // the sidebar's list or the search field.
                window.makeFirstResponder(nil)
            }
        }
    }

    // MARK: - Text

    /// Puts the composer's text in the view when the two differ: a draft restored when the
    /// chat opens, the field emptied by a send, a failed reply handed back.
    func applyTextFromComposer() {
        guard let textView, textView.string != field.text else { return }
        // Text an input method is still composing is the view's alone. Replacing the string
        // under it would throw the composition away.
        guard !textView.hasMarkedText() else { return }
        textView.string = field.text
        // The text was replaced from outside, so nothing typed before it can be undone into
        // it: Undo after a send must not bring back the mail that was just sent.
        textView.undoManager?.removeAllActions()
        textView.enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        if field.text != textView.string {
            field.text = textView.string
        }
        textView.enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    // MARK: - Keys

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let command = ReplyFieldKeyPolicy.Command(
            selectorName: NSStringFromSelector(commandSelector)
        ) else {
            return false
        }
        let key = field.currentKey()
        let action = ReplyFieldKeyPolicy.action(
            for: command,
            context: ReplyFieldKeyPolicy.Context(
                isShiftDown: key.isShiftDown,
                isKeyRepeat: key.isRepeat,
                hasMarkedText: textView.hasMarkedText(),
                // Asked of the text in the view now, not of the composer's copy, which this
                // key's own change may not have reached yet.
                canSend: field.canSend(textView.string)
            )
        )
        switch action {
        case .send:
            // The composer sends its own copy of the text; make it this one first.
            if field.text != textView.string {
                field.text = textView.string
            }
            field.onSend()
        case .insertNewline:
            textView.insertNewlineIgnoringFieldEditor(nil)
        case .commitMarkedText:
            textView.unmarkText()
        case .ignore:
            break
        case .cancel:
            field.onCancel()
        }
        // Every command the policy names is taken here; the text view does nothing more.
        return true
    }

    // MARK: - Height

    /// The field's height for its text at a width: the text's own, at least one line and at
    /// most `maximumLineCount` lines, past which the text scrolls inside the field.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let font = self.font
        let lineHeight = measuringLayoutManager.defaultLineHeight(for: font)
        let text = textView?.string ?? field.text
        measuringContainer.size = NSSize(
            width: max(width, 1),
            height: CGFloat.greatestFiniteMagnitude
        )
        measuringStorage.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        measuringLayoutManager.ensureLayout(for: measuringContainer)
        let textHeight = measuringLayoutManager.usedRect(for: measuringContainer).height
        return MacReplyTextField.clampedHeight(
            textHeight: textHeight,
            lineHeight: lineHeight,
            maximumLineCount: field.maximumLineCount
        )
    }
}
#endif
