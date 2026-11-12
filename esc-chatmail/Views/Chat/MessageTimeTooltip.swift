import SwiftUI

/// The message's exact time as a tooltip on its bubble, where the style draws no timestamp
/// under it (`MessageBubbleStyle.showsTimestampUnderBubble`). A style that does draw one gets
/// the view back untouched: `help` is also an accessibility hint, which the iOS row never had.
struct MessageTimeTooltip: ViewModifier {
    /// The date to show, or nil for no tooltip. Fixed by the style for the row's life.
    let date: Date?

    func body(content: Content) -> some View {
        if let date {
            content.help(Text(date, format: Date.FormatStyle(date: .complete, time: .shortened)))
        } else {
            content
        }
    }
}
