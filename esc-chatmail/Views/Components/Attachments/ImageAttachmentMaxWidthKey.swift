import SwiftUI

private struct ImageAttachmentMaxWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The widest an image attachment draws, or nil for `ImageAttachmentBubble`'s own cap. The
    /// bubble's style sets it (`MessageBubbleStyle.imageMaxWidth(transcriptWidth:)`); it is in the environment
    /// because the image is several views below the bubble that knows the style.
    var imageAttachmentMaxWidth: CGFloat? {
        get { self[ImageAttachmentMaxWidthKey.self] }
        set { self[ImageAttachmentMaxWidthKey.self] = newValue }
    }
}
