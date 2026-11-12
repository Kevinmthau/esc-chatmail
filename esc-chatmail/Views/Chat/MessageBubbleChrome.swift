import SwiftUI

/// A bubble's padding, fill and outline, for the text bubble, the forwarded bubble, the loading
/// pill and the no-preview placeholder.
///
/// A style without a tail draws what those four drew before a style had one: the fill, clipped
/// to a rounded rectangle. A style with a tail fills a `BubbleShape`, which draws the tail
/// outside the bubble's frame, so nothing is clipped.
struct MessageBubbleChrome: ViewModifier {
    let style: MessageBubbleStyle
    let padding: EdgeInsets
    let fill: Color
    /// The corner radius where the style has no tail. The placeholder's is its own.
    let cornerRadius: CGFloat
    /// The bubble's tail, nil for none (`MessageBubbleRowPolicy.tail`). Ignored by a style
    /// whose bubbles have no tail.
    let tail: BubbleShape.Tail?

    func body(content: Content) -> some View {
        if style.bubbleTailWidth > 0 {
            content
                .padding(padding)
                .background {
                    BubbleShape(
                        cornerRadius: style.bubbleCornerRadius,
                        tail: tail,
                        tailWidth: style.bubbleTailWidth
                    )
                    .fill(fill)
                }
        } else {
            content
                .padding(padding)
                .background(fill)
                .cornerRadius(cornerRadius)
        }
    }
}

extension View {
    /// A message bubble in the style's own padding, fill and corner radius.
    func messageBubbleChrome(
        style: MessageBubbleStyle,
        isFromMe: Bool,
        tail: BubbleShape.Tail?
    ) -> some View {
        modifier(MessageBubbleChrome(
            style: style,
            padding: style.bubblePadding,
            fill: style.bubbleBackground(isFromMe: isFromMe),
            cornerRadius: style.bubbleCornerRadius,
            tail: tail
        ))
    }
}
