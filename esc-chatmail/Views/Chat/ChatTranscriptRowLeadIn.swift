import SwiftUI

/// What a transcript row draws above its bubble, inside the row: the time line, or the space
/// that separates one run of bubbles from the next (`ChatTranscriptRunPlacement`).
///
/// Inside the row, so the stack's spacing stays one constant and the time line is no row of
/// its own. The style decides once whether a row has a lead-in at all, and a style without one
/// gets the row back untouched: the iOS row's view tree is what it was. Within a style that
/// has one, a time line coming or going changes only the stack's first child, never the
/// bubble's identity, so the bubble keeps its view model.
struct ChatTranscriptRowLeadIn: ViewModifier {
    let style: MessageBubbleStyle
    let placement: ChatTranscriptRunPlacement

    func body(content: Content) -> some View {
        if style.showsTimestampSeparators {
            VStack(spacing: 0) {
                if let separatorDate = placement.separatorDate {
                    ChatTimestampSeparator(date: separatorDate)
                }
                content
            }
            .padding(.top, placement.topPadding)
        } else {
            content
        }
    }
}
