#if os(macOS)
import AppKit

/// Whether the window a menu command acts on has a sheet attached, read from AppKit at the
/// moment it is asked (`SignOutMenuPolicy.choice`).
///
/// A SwiftUI `.sheet`, `.alert`, `.confirmationDialog` and file importer are all sheets on the
/// Mac, and a window shows one at a time: a second one is queued until the first closes. While a
/// sheet is up it is the key window and the window it is attached to is the main window, so both
/// are checked. The answer is never stored or counted, so it cannot stay true after the sheet
/// has gone.
@MainActor
enum FocusedWindowSheet {
    static var isAttached: Bool {
        let application = NSApplication.shared
        return application.keyWindow?.sheetParent != nil
            || application.keyWindow?.attachedSheet != nil
            || application.mainWindow?.attachedSheet != nil
    }
}
#endif
