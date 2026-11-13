import SwiftUI

extension View {
    /// Gives an attachment in a Mac chat its menu: Quick Look, Save Attachment… and Save All
    /// Attachments… (`MacAttachmentExportMenu`). Nothing on iOS, where the view is returned as
    /// it is.
    ///
    /// - Parameters:
    ///   - attachment: The attachment this view shows.
    ///   - shownAttachments: Every attachment the message shows.
    ///   - onQuickLook: Opens Quick Look on this attachment, as a click on it does.
    @ViewBuilder
    func macAttachmentExportMenu(
        attachment: Attachment,
        shownAttachments: [Attachment],
        onQuickLook: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        modifier(
            MacAttachmentExportMenu(
                attachment: attachment,
                shownAttachments: shownAttachments,
                onQuickLook: onQuickLook
            )
        )
        #else
        self
        #endif
    }
}
