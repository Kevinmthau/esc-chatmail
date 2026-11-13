import SwiftUI

extension View {
    /// Lets an attachment in a Mac chat be dragged out to the Finder or another app, as a
    /// promise of its file under the name a save would offer (`MacAttachmentDragSourceView`).
    /// Nothing on iOS, where the view is returned as it is.
    ///
    /// The drag source is in front of the attachment and takes its clicks, so it is there only
    /// while the attachment has its file, and hands a click on to `onClick`. Apply it before
    /// `macAttachmentExportMenu`, so the menu's view contains it.
    ///
    /// - Parameters:
    ///   - attachment: The attachment this view shows.
    ///   - onClick: What a click on the attachment does: opens Quick Look on it.
    @ViewBuilder
    func macAttachmentDragSource(
        attachment: Attachment,
        onClick: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        overlay {
            if attachment.isReady {
                MacAttachmentDragSource(
                    resolveItem: { AttachmentExportItem(attachment: attachment) },
                    onClick: onClick
                )
                .accessibilityHidden(true)
            }
        }
        #else
        self
        #endif
    }
}
