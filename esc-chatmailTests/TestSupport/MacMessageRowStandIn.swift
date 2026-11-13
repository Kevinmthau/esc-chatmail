#if os(macOS)
import SwiftUI
@testable import esc_chatmail

/// Where things are in a `MacMessageRowStandIn`, in window coordinates (y up) of a window the
/// size of the row: the text is the upper half and the attachments the lower, one cell each
/// from the left.
enum MacMessageRowStandInLayout {
    static let cell: CGFloat = 100

    static func size(columns: Int) -> CGSize {
        CGSize(width: cell * CGFloat(columns), height: cell * 2)
    }

    /// A point on the message's text, over no attachment.
    static func pointOnText(columns: Int) -> NSPoint {
        NSPoint(x: cell * CGFloat(columns) / 2, y: cell * 1.5)
    }

    /// A point on the attachment in cell `index`.
    static func pointOnAttachment(_ index: Int = 0) -> NSPoint {
        NSPoint(x: cell * (CGFloat(index) + 0.5), y: cell * 0.5)
    }
}

/// A message's row as far as the mouse and the menus go: text above, its attachments in a line
/// below, and the row's own menu (with a preview) around both, its entries handed down to the
/// views inside as `ChatMessagesView` hands its own (`View.macEnclosingMessageMenu`).
///
/// One stand-in for the suites that mount something on an attachment, so that what the real
/// row does around an attachment is written down once. The attachments' own views are each
/// suite's: a cell is `MacMessageRowStandInLayout.cell` square.
///
/// With `inAMessageRow` false, the attachments alone, with no menu around them.
struct MacMessageRowStandIn<Attachments: View>: View {
    /// How many cells wide the row is.
    let columns: Int
    var inAMessageRow = true
    /// The title of an entry of the message's menu that was chosen, from either menu.
    let onMessageAction: (String) -> Void
    @ViewBuilder let attachments: () -> Attachments

    var body: some View {
        if inAMessageRow {
            content
                .contentShape(Rectangle())
                .macEnclosingMessageMenu { messageEntries }
                .contextMenu { messageEntries } preview: {
                    Text("Preview")
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var messageEntries: some View {
        Button("Reply") { onMessageAction("Reply") }
        Button("Forward") { onMessageAction("Forward") }
    }

    private var content: some View {
        let cell = MacMessageRowStandInLayout.cell
        return VStack(alignment: .leading, spacing: 0) {
            Text("The message's text")
                .frame(width: cell * CGFloat(columns), height: cell)
            HStack(spacing: 0) {
                attachments()
            }
            .frame(width: cell * CGFloat(columns), height: cell, alignment: .leading)
        }
    }
}
#endif
