import SwiftUI

extension View {
    /// Gives a sheet's content its size on the Mac (`MacSheetSize` says why it needs one); nil
    /// leaves a sheet that sizes itself alone. Changes nothing on iOS, where a sheet fills the
    /// screen or its detents.
    func macSheetSize(_ size: MacSheetSize?) -> some View {
        #if os(macOS)
        frame(
            minWidth: size?.minWidth,
            idealWidth: size?.idealWidth,
            minHeight: size?.minHeight,
            idealHeight: size?.idealHeight
        )
        #else
        self
        #endif
    }

    /// Adds a Done button to a Mac sheet that has no control of its own to close it
    /// (`MacSheetDoneBar`). Changes nothing on iOS, where the sheet is swiped down.
    @ViewBuilder
    func macSheetDoneBar(_ isShown: Bool) -> some View {
        #if os(macOS)
        if isShown {
            modifier(MacSheetDoneBar())
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Makes Command-Return the Mac shortcut of a sheet's Send button. Placed at
    /// `ToolbarItemPlacement.sheetTrailingBarEdge` the button is the sheet's default button,
    /// which a bare Return presses whenever no text field has the focus; a send cannot be taken
    /// back, so it must not be one stray key away. An explicit shortcut replaces that default
    /// (measured on macOS 27.2, 2026-11-10). Changes nothing on iOS.
    func macSendKeyboardShortcut() -> some View {
        #if os(macOS)
        keyboardShortcut(.return, modifiers: .command)
        #else
        self
        #endif
    }
}
