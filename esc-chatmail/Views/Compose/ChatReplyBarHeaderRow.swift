import SwiftUI

/// The row above the iPhone's reply field that says what the reply answers and who gets it
/// (`ReplyIndicatorPolicy.Header`). The Mac's is `MacReplyIndicator`.
///
/// It says who gets a reply that goes to people the chat's title does not name, and those
/// addresses are the sender's to choose: how many there are, and how long each is. Two things
/// follow, and both are sizes, which is why this is a view of its own that a test can mount
/// and measure (`ChatReplyBarHeaderRowTests`).
///
/// A row of text is no taller than `ReplyIndicatorPolicy.wrappingLabelMaxHeight`, and text
/// that needs more scrolls there. The composer's height is the transcript's bottom inset, so
/// a row as tall as its text let one message's Reply-To header take the screen.
///
/// And the quote row, which is one line and so draws the short label, opens on a tap to draw
/// the whole one (`ReplyIndicatorPolicy.quoteRow`). The short label cuts a long address in its
/// middle and counts recipients it does not name, and the line's end can cut it again: two
/// addresses can then be drawn the same, and a sighted user had nowhere to see either whole.
struct ChatReplyBarHeaderRow: View {
    let header: ReplyIndicatorPolicy.Header
    /// Whether the row's buttons take a tap (`ChatReplyBarControlPolicy.allowsDraftMutation`).
    let allowsDraftMutation: Bool
    /// Whether the user has opened the quote row. `ChatReplyBar` owns it and closes the row
    /// whenever the header changes.
    @Binding var isQuoteRowOpen: Bool
    let onDropQuote: () -> Void
    let onClearUnavailableTarget: () -> Void

    var body: some View {
        switch header {
        case .unavailableTarget:
            HStack {
                Text("Original reply target unavailable")
                Spacer()
                Button("Clear target", action: onClearUnavailableTarget)
                    .disabled(!allowsDraftMutation)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        case .recoveredEnvelope(let label):
            textRow(label)
        case .addressedTo(let label, let unabridgedLabel):
            // This row wraps and shares its lines with nothing, so it draws every
            // recipient's address whole: the short label is for a row of one line.
            textRow(ReplyIndicatorPolicy.wholeLabel(label, unabridged: unabridgedLabel))
        case .replyingTo(let label, let unabridgedLabel):
            quoteRow(label: label, unabridgedLabel: unabridgedLabel)
        case .none:
            EmptyView()
        }
    }

    /// A header row of text alone.
    private func textRow(_ label: String) -> some View {
        boundedLabel(label, fillsWidth: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    /// The dismissible "Replying to" row. Its X drops the quote; a tap anywhere else on a row
    /// that announces recipients opens it, or closes it again.
    private func quoteRow(label: String, unabridgedLabel: String?) -> some View {
        let row = ReplyIndicatorPolicy.quoteRow(
            label: label,
            unabridgedLabel: unabridgedLabel,
            isOpen: isQuoteRowOpen
        )
        return HStack {
            Image(systemName: "arrow.turn.up.left")
                .font(.caption)
                .foregroundColor(.secondary)

            if row.wraps {
                boundedLabel(row.text, fillsWidth: true)
            } else {
                Text(row.text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    // One line, so it draws the short label, which can cut an address and
                    // count recipients it does not name. VoiceOver reads the whole one.
                    .accessibilityLabel(ReplyIndicatorPolicy.wholeLabel(label, unabridged: unabridgedLabel))
            }

            if row.opens {
                // The only sign that the row opens. VoiceOver has no use for it: it is read
                // the whole label either way.
                Image(systemName: row.wraps ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }

            // The open label takes the row's width itself. Beside a spacer it would be
            // given half of it.
            if !row.wraps {
                Spacer()
            }

            Button(action: onDropQuote) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .disabled(!allowsDraftMutation)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.1))
        .contentShape(Rectangle())
        // Not animated: the row's height is part of the composer's, and the transcript takes
        // a growth of its bottom inset in one frame (`ChatBottomInsetPolicy`).
        .gesture(row.opens ? TapGesture().onEnded { isQuoteRowOpen.toggle() } : nil)
    }

    /// `text` on as many lines as it needs, in no more height than
    /// `ReplyIndicatorPolicy.wrappingLabelMaxHeight`. Text that needs more scrolls there, so
    /// nothing of it is cut off and nothing has to be counted.
    ///
    /// Text that fits is drawn with no scroll view around it, as it always was: the scroll
    /// view is the second choice, taken only where the first is too tall. The choice is made
    /// on the vertical axis alone, so the text is measured at the row's width, wrapped.
    ///
    /// The limit and `fixedSize` go together. A frame with a greatest height is as tall as
    /// that height wherever it is offered more, whatever it holds: without `fixedSize` a row
    /// naming one person was as tall as the limit. With it the frame is asked for its own
    /// height, which is the text's, and the limit only caps that.
    private func boundedLabel(_ text: String, fillsWidth: Bool) -> some View {
        ViewThatFits(in: .vertical) {
            labelText(text, fillsWidth: fillsWidth)
            ScrollView(.vertical) {
                labelText(text, fillsWidth: fillsWidth)
            }
            // Nothing else says there is more below the last line the row shows.
            .scrollIndicatorsFlash(onAppear: true)
        }
        .frame(maxHeight: ReplyIndicatorPolicy.wrappingLabelMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Text that wraps, so its addresses are marked to be broken with no hyphen added
    /// (`ReplyIndicatorPolicy.wrappingLabel`).
    private func labelText(_ text: String, fillsWidth: Bool) -> some View {
        Text(ReplyIndicatorPolicy.wrappingLabel(text))
            // The mark is for line breaking only. VoiceOver is given the plain text, as it
            // was before the addresses were marked: what it does with text marked as being in
            // no language has not been heard.
            .accessibilityLabel(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }
}
