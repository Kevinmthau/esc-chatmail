#if os(macOS)
import AppKit

/// The panels and the alert `MacAttachmentExporter` shows, as sheets on the app's window.
///
/// Not seen: none of this can be shown in a test host, and no Mac build of the app has been
/// launched (`docs/mac-app-plan.md`, "Files"). What the tests cover stops at the closures the
/// exporter is given in place of these.
@MainActor
enum MacAttachmentSavePanels {
    /// The window a panel is attached to: the app's one window. A right-click does not have to
    /// make its window key, so the main window is asked first and the key window is not asked
    /// alone.
    static var window: NSWindow? {
        let application = NSApplication.shared
        return application.mainWindow
            ?? application.keyWindow
            ?? application.windows.first(where: { $0.isVisible && $0.canBecomeMain })
    }

    static func chooseFile(suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        // The name is the attachment's whole name, and its extension says what the file is.
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        let response = await run(panel)
        return response == .OK ? panel.url : nil
    }

    static func chooseFolder(count: Int) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = AttachmentExportPolicy.folderPrompt(count: count)
        let response = await run(panel)
        return response == .OK ? panel.url : nil
    }

    static func presentFailure(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// A sheet on the app's window. With no window, or one that already has a sheet, the panel
    /// is a window of its own: a second sheet would wait unseen behind the first.
    private static func run(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        if let window, window.attachedSheet == nil {
            return await panel.beginSheetModal(for: window)
        }
        return await panel.begin()
    }
}
#endif
