#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether something modal covers the app's foreground window right now, wherever in the
/// view tree it was presented from: a sheet, an alert or a confirmation dialog, a photo
/// picker or file importer, and on iOS Quick Look, which is its own UIKit modal
/// (`QuickLookPreviewController`).
///
/// For work that ends late and then opens a sheet of its own, such as a forward that waited
/// for its attachments (`ChatViewModel.setMessageToForward`): a view cannot present while
/// another presentation covers it, and a sheet asked for then is never shown, though its state
/// stays set. The Mac's Quick Look panel is a window of its own beside the app's and does not
/// count.
enum AppModalPresentation {
    @MainActor
    static func isShowing() -> Bool {
        #if os(iOS)
        TopPresentableViewController.foregroundWindowHasPresentation()
        #elseif os(macOS)
        guard let app = NSApp else { return false }
        if app.modalWindow != nil { return true }
        guard let window = app.keyWindow ?? app.mainWindow else { return false }
        return window.attachedSheet != nil
        #else
        false
        #endif
    }
}
