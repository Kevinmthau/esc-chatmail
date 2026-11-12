import SwiftUI

/// The text content's own cap inside a row's column, for a style whose column can be wider
/// than its text (`MessageBubbleStyle.textContentMaxWidth`): on the Mac the column also holds
/// images, which are wider than the text's share of a narrow transcript.
///
/// A style with no cap of its own gets the content back untouched, so the iOS row's view tree
/// is what it was. Whether there is a cap is the style's to say and never changes for a row,
/// so the branch never remounts the text.
struct MessageTextWidthCap: ViewModifier {
    /// The cap, or nil for none.
    let maxWidth: CGFloat?
    /// The side the text keeps to inside the cap: the row's own.
    let isFromMe: Bool

    func body(content: Content) -> some View {
        if let maxWidth {
            content.frame(maxWidth: maxWidth, alignment: isFromMe ? .trailing : .leading)
        } else {
            content
        }
    }
}
