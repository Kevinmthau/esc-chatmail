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
    /// The composer's text as the field last knew it: what the view last gave the composer, or
    /// what the composer last gave the view. While an input method is composing, the view runs
    /// ahead of the composer by the word being composed, and this is how
    /// `applyTextFromComposer` tells that apart from the composer replacing its text.
    private var composerTextKnownToField: String
    /// `applyTextFromComposer` is changing the view: what the view then reports as a change is
    /// the composer's own text, not something to give the composer.
    private var isApplyingComposerText = false
    /// The field's own undo history. Without one a text view records in its window's, which
    /// the search field and everything else in the window share, and emptying it after a send
    /// (`applyTextFromComposer`) emptied theirs too.
    private let fieldUndoManager = UndoManager()

    /// A second text layout, used only to measure: the height of a string at a width, without
    /// touching the layout the view draws from.
    private let measuringStorage = NSTextStorage()
    private let measuringLayoutManager = NSLayoutManager()
    private let measuringContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )

    init(field: MacReplyTextField) {
        self.field = field
        composerTextKnownToField = field.text
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
                bridge.attach(
                    field: self,
                    applyFocus: { [weak self] wantsFocus in self?.applyFocus(wantsFocus) },
                    commitPendingInput: { [weak self] in self?.commitMarkedText() }
                )
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
        guard let textView else { return }
        let composerText = field.text
        guard textView.string != composerText else {
            composerTextKnownToField = composerText
            return
        }
        if textView.hasMarkedText() {
            // The view tells the composer nothing about a word an input method is still
            // composing, so while one is, the two differ and the composer is not wrong:
            // replacing the string then would throw the composition away on any update.
            guard composerText != composerTextKnownToField else { return }
            // The composer's text was replaced from outside while a word was being composed.
            // Its text wins, and the composition goes: left in place, the view kept all it
            // showed, and the next change gave it back to the composer. After a send that was
            // the mail just sent, back in the draft; after a failed reply was handed over, it
            // was that reply gone.
            textView.inputContext?.discardMarkedText()
        }
        isApplyingComposerText = true
        textView.string = composerText
        // Marking that outlived its text: end it without telling the composer of a change.
        if textView.hasMarkedText() { textView.unmarkText() }
        isApplyingComposerText = false
        composerTextKnownToField = composerText
        // The text was replaced from outside, so nothing typed before it can be undone into
        // it: Undo after a send must not bring back the mail that was just sent.
        fieldUndoManager.removeAllActions()
        textView.enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView, !isApplyingComposerText else { return }
        giveComposerTheViewsText(textView)
        textView.enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    private func giveComposerTheViewsText(_ textView: NSTextView) {
        if field.text != textView.string {
            field.text = textView.string
        }
        composerTextKnownToField = textView.string
    }

    /// Commits the word an input method is still composing, so the composer holds all the
    /// field shows. Asked for by the send arrow before it sends
    /// (`ReplyFieldFocusBridge.commitPendingInput`): a click on the arrow does not end a
    /// composition, and the composer's copy lacks the word until it is committed, so the reply
    /// went without it.
    func commitMarkedText() {
        guard let textView, textView.hasMarkedText() else { return }
        textView.unmarkText()
        textView.inputContext?.discardMarkedText()
        // Whether or not the view reported the commit as a change.
        giveComposerTheViewsText(textView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        fieldUndoManager
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
            giveComposerTheViewsText(textView)
            field.onSend()
        case .insertNewline:
            textView.insertNewlineIgnoringFieldEditor(nil)
        case .commitMarkedText:
            commitMarkedText()
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
