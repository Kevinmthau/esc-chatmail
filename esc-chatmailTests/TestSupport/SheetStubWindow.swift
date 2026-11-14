#if os(macOS)
import AppKit

/// A window that answers `attachedSheet` and `sheetParent` with the windows it is given.
/// AppKit attaches a real sheet only to a window on screen, and these are never ordered in.
///
/// A window holds its sheet and the sheet only names its window (`stubbedSheetParent` is
/// weak). Held both ways, neither was ever released, and a window that is never shown is
/// still one of `NSApp.windows` for as long as it lives (measured on macOS 27.2,
/// 2026-11-13): every stand-in made with a sheet stayed in the test host as a mailbox window
/// with a sheet attached, for every suite that ran after it.
final class SheetStubWindow: NSWindow {
    var stubbedSheet: NSWindow?
    weak var stubbedSheetParent: NSWindow?

    override var attachedSheet: NSWindow? {
        stubbedSheet
    }

    override var sheetParent: NSWindow? {
        stubbedSheetParent
    }

    /// A window that is never shown, with `identifier` and, if `hasSheet`, a sheet attached.
    @MainActor
    static func make(identifier: String?, hasSheet: Bool) -> SheetStubWindow {
        let window = SheetStubWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        if hasSheet {
            let sheet = SheetStubWindow(
                contentRect: NSRect(x: -30_000, y: -30_000, width: 50, height: 50),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            sheet.isReleasedWhenClosed = false
            sheet.stubbedSheetParent = window
            window.stubbedSheet = sheet
        }
        return window
    }
}
#endif
