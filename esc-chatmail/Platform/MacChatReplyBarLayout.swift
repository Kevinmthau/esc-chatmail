#if os(macOS)
import AppKit
import SwiftUI

/// The Mac's floating composer, as in Messages (`docs/mac-imessage-ui-plan.md`, PR 5): the
/// reply indicator and the attachment strip over a row holding the "+" button and the field.
/// Inside the field, after the text: an emoji button and, while there is something to send, a
/// send arrow.
///
/// Layout only. `ChatReplyBar` owns the draft and fills the three slots, and every send goes
/// through its `onSend` behind its `canSend`, from Return and from the arrow alike.
///
/// Nothing is drawn behind the rows: the transcript shows between them
/// (`ChatComposerPolicy.Backdrop.fade`). The field has a fill of its own so the draft is always
/// read against the window's background, never against a bubble passing under it.
struct MacChatReplyBarLayout<Indicator: View, Attachments: View, AttachmentMenu: View>: View {
    let metrics: ChatComposerMetrics
    @Binding var text: String
    let placeholder: String
    /// Whether the send arrow is drawn (`ChatComposerPolicy.showsSendArrow`).
    let showsSendArrow: Bool
    /// Whether the send arrow takes a click (`ChatReplyBar.canSend`).
    let isSendEnabled: Bool
    let focusBridge: ReplyFieldFocusBridge
    let canSend: (String) -> Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let indicator: () -> Indicator
    @ViewBuilder let attachments: () -> Attachments
    @ViewBuilder let attachmentMenu: () -> AttachmentMenu

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            indicator()
            attachments()
            HStack(alignment: .bottom, spacing: metrics.controlSpacing) {
                attachmentMenu()
                field
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.fieldCornerRadius, style: .continuous)
    }

    /// What keeps a button inside the field on the field's last line: the space under it when
    /// the field is one line tall.
    private var inFieldButtonBottomPadding: CGFloat {
        max(0, (metrics.controlDiameter - metrics.inFieldButtonSide) / 2)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: metrics.inFieldButtonSpacing) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: metrics.fontSize))
                        .foregroundStyle(Color.placeholderText)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                MacReplyTextField(
                    text: $text,
                    fontSize: metrics.fontSize,
                    maximumLineCount: metrics.maximumLineCount,
                    focusBridge: focusBridge,
                    canSend: canSend,
                    onSend: onSend,
                    onCancel: onCancel
                )
            }
            .padding(.vertical, metrics.fieldVerticalPadding)

            emojiButton
                .padding(.bottom, inFieldButtonBottomPadding)

            if showsSendArrow {
                sendArrow
                    .padding(.bottom, inFieldButtonBottomPadding)
            }
        }
        .padding(.leading, metrics.fieldLeadingPadding)
        .padding(.trailing, metrics.fieldTrailingPadding)
        // At least as tall as the "+" button beside it, and no shorter for having no arrow:
        // the arrow comes and goes with the draft, and the composer's height is part of the
        // transcript's bottom inset.
        .frame(minHeight: metrics.controlDiameter)
        .background(fieldShape.fill(Color.systemBackground))
        .overlay(fieldShape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        // A click on the field's padding, beside or under the text, puts the caret in it.
        .contentShape(fieldShape)
        .onTapGesture { focusBridge.requestFocus(true) }
    }

    private var emojiButton: some View {
        Button {
            // The palette types into whatever has the focus, so the field takes it first.
            focusBridge.requestFocus(true)
            DispatchQueue.main.async {
                NSApp.orderFrontCharacterPalette(nil)
            }
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: metrics.inFieldButtonSide * 0.72))
                .foregroundStyle(.secondary)
                .frame(width: metrics.inFieldButtonSide, height: metrics.inFieldButtonSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Emoji & Symbols")
        .accessibilityLabel("Emoji and symbols")
    }

    private var sendArrow: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    Color.white,
                    isSendEnabled ? Color.accentColor : Color.systemGray3
                )
                .frame(width: metrics.inFieldButtonSide, height: metrics.inFieldButtonSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isSendEnabled)
        .help("Send")
        .accessibilityLabel("Send")
    }
}
#endif
