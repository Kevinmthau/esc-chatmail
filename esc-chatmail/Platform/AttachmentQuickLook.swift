#if os(macOS)
import QuickLookUI
#endif

/// Closes attachment Quick Look at the account boundary.
@MainActor
enum AttachmentQuickLook {
    /// Closes every attachment Quick Look still on screen, so a sign-out or a revoked credential
    /// never leaves the previous account's document over the sign-in view.
    ///
    /// iOS: `QuickLookPreviewController.dismissAll()`, whose modal outlives the mailbox. The Mac:
    /// the shared Quick Look panel, which `.quickLookPreview` shows as its own window and which
    /// could likewise outlive the views that opened it. It is only closed when it already exists,
    /// so this never creates one.
    static func dismissAll() {
        #if os(iOS)
        QuickLookPreviewController.dismissAll()
        #else
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else {
            return
        }
        panel.orderOut(nil)
        #endif
    }
}
