#if os(macOS)
import AppKit
import SwiftUI

/// The Mac's reply field: an `NSTextView` in which Return sends
/// (`docs/mac-imessage-ui-plan.md`, PR 5).
///
/// Not SwiftUI's `TextField`, for two things the spike measured. Left alone, Shift-Return in a
/// `TextField` submits, the same as Return. And after any submit that leaves the text in place
/// (a send refused because an attachment is still being read), a `TextField` selects the whole
/// draft, so the next key replaces it. A text view does neither: it hands its delegate the text
/// system's commands, after an input method has had the key, and the delegate decides each
/// (`ReplyFieldKeyPolicy`).
///
/// The view draws only the text. The capsule around it, the placeholder and the buttons are
/// `MacChatReplyBarLayout`'s. It is one line tall when empty and grows with its text to
/// `maximumLineCount` lines, then scrolls.
///
/// SwiftUI's `FocusState` does not reach an `NSTextView`, so the field reports its focus to,
/// and takes requests from, the chat's `ReplyFieldFocusBridge`.
struct MacReplyTextField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let maximumLineCount: Int
    let focusBridge: ReplyFieldFocusBridge
    /// Whether the composer would send the text given, asked as Return is pressed.
    let canSend: (String) -> Bool
    /// Return was pressed and `canSend` said yes.
    let onSend: () -> Void
    /// Escape was pressed.
    let onCancel: () -> Void
    /// The key being handled, for Shift and key repeat. Tests give their own.
    var currentKey: @MainActor () -> MacReplyKeyEvent = MacReplyKeyEvent.current

    func makeCoordinator() -> MacReplyTextFieldCoordinator {
        MacReplyTextFieldCoordinator(field: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, built by hand: the coordinator measures the field's height with a layout
        // manager, and asking a default text view for its layout manager would switch it from
        // TextKit 2 after the fact.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = MacReplyTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.font = context.coordinator.font
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("Message")
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView

        context.coordinator.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.field = self
        if let textView = context.coordinator.textView {
            let font = context.coordinator.font
            if textView.font != font {
                textView.font = font
                scrollView.invalidateIntrinsicContentSize()
            }
        }
        context.coordinator.applyTextFromComposer()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        // As wide as it is offered, and as tall as its text at that width.
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.fittingHeight(forWidth: width))
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: MacReplyTextFieldCoordinator) {
        coordinator.detach()
    }

    /// The field's height for text of `textHeight`: whole points, at least one line, at most
    /// `maximumLineCount` lines.
    static func clampedHeight(
        textHeight: CGFloat,
        lineHeight: CGFloat,
        maximumLineCount: Int
    ) -> CGFloat {
        let most = lineHeight * CGFloat(max(maximumLineCount, 1))
        return ceil(min(max(textHeight, lineHeight), most))
    }
}
#endif
