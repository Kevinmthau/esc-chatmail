import CoreGraphics

/// The sizes of the Mac's floating composer (`ChatComposerStyle.floating`).
///
/// Every number in `mac` is a first reading of a screenshot of Messages on macOS 26, not a
/// measurement, and none of it has been seen in the app (`docs/mac-imessage-ui-plan.md`,
/// "PR 5 as built").
struct ChatComposerMetrics: Equatable {
    /// Between the chat column's edges and the composer.
    ///
    /// Above 20 points, for the reason the header's name capsule keeps clear of the column's
    /// edges (`ChatHeaderMetrics.nameBarHorizontalPadding`): drawn off screen, a glass shape
    /// that came within 20 points of both edges of the transcript it sits over took the
    /// transcript out of the drawing. The "+" button is the composer's only glass, and it is
    /// small, but it is kept clear all the same.
    let horizontalPadding: CGFloat
    /// Above and below the composer's rows.
    let verticalPadding: CGFloat
    /// Between the composer's rows: the reply indicator, the attachment strip and the field.
    let rowSpacing: CGFloat
    /// The "+" button's diameter, and the least height of the field beside it, so the two line
    /// up on one row.
    let controlDiameter: CGFloat
    /// Between the "+" button and the field.
    let controlSpacing: CGFloat
    /// The field's corner radius: half its one-line height, so one line of text sits in a
    /// capsule. A taller field keeps the radius and becomes a rounded rectangle.
    let fieldCornerRadius: CGFloat
    /// Between the field's leading edge and its text.
    let fieldLeadingPadding: CGFloat
    /// Between the field's trailing edge and the buttons inside it.
    let fieldTrailingPadding: CGFloat
    /// Above and below the text inside the field.
    let fieldVerticalPadding: CGFloat
    /// The size of the text typed in the field, in points.
    let fontSize: CGFloat
    /// The most lines the field grows to before its text scrolls.
    let maximumLineCount: Int
    /// The side of the emoji button and of the send arrow inside the field. No taller than the
    /// field's one-line height less its padding, so the arrow coming and going with the draft
    /// never changes the field's height.
    let inFieldButtonSide: CGFloat
    /// Between the buttons inside the field, and between them and the text.
    let inFieldButtonSpacing: CGFloat
    /// The height of the reply indicator's capsule.
    let replyIndicatorHeight: CGFloat

    static let mac = ChatComposerMetrics(
        horizontalPadding: 24,
        verticalPadding: 10,
        rowSpacing: 6,
        controlDiameter: 30,
        controlSpacing: 8,
        fieldCornerRadius: 15,
        fieldLeadingPadding: 12,
        fieldTrailingPadding: 4,
        fieldVerticalPadding: 7,
        fontSize: 13,
        maximumLineCount: 5,
        inFieldButtonSide: 22,
        inFieldButtonSpacing: 4,
        replyIndicatorHeight: 22
    )
}
