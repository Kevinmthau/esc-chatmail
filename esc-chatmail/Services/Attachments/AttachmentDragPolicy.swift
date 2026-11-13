import CoreGraphics

/// The mouse over an attachment that can be dragged out of a Mac chat
/// (`MacAttachmentDragSourceView`): when a press becomes a drag, when it is a click, and where
/// the drag may be dropped.
enum AttachmentDragPolicy {
    /// Whether the view over the attachment takes the mouse at all, asked at every press. Only
    /// while the attachment is still there and has its file. The view is put there when the
    /// row is drawn, and the attachment can change before the row is drawn again: a file that
    /// went missing is downloaded again, and where that fails the attachment's own button and
    /// its retry control must get the click, not a view that would open Quick Look on nothing.
    static func takesMouse(isLive: Bool, isReady: Bool) -> Bool {
        isLive && isReady
    }

    /// How far the pointer moves with the button down before the press is a drag. Less is
    /// the hand's own movement during a click.
    static let dragThreshold: CGFloat = 4

    static func startsDrag(from pressLocation: CGPoint, to location: CGPoint) -> Bool {
        let distance = hypot(location.x - pressLocation.x, location.y - pressLocation.y)
        return distance >= dragThreshold
    }

    /// Whether a release ends a click, which opens Quick Look as a click on the attachment
    /// always has. A press that became a drag is not one, whether or not the drag found a
    /// file to carry; neither is a press the pointer left before the button came up.
    static func isClick(didStartDrag: Bool, releasedInside: Bool) -> Bool {
        !didStartDrag && releasedInside
    }

    /// Whether the drag may be dropped as a copy. Only outside the app: nothing in the app
    /// takes an attachment back, and the reply field's text view and an email's web view must
    /// not be offered one.
    static func allowsCopy(outsideApplication: Bool) -> Bool {
        outsideApplication
    }
}
