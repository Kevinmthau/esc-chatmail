import SwiftUI

extension View {
    /// Gives a sheet's content its Mac size and, where asked for, the Done bar
    /// (`MacSheetChromeModifier`). `View.appSheet` applies it to every sheet. Changes nothing on
    /// iOS, where a sheet fills the screen or its detents and is swiped down.
    func macSheetChrome(_ chrome: MacSheetChrome) -> some View {
        #if os(macOS)
        modifier(MacSheetChromeModifier(chrome: chrome))
        #else
        self
        #endif
    }

    /// Makes Escape close the Mac sheet this view is in, for a sheet whose own Done button
    /// answers Return (`MacSheetEscapeCloses`). Changes nothing on iOS.
    func macSheetClosesOnEscape() -> some View {
        #if os(macOS)
        modifier(MacSheetEscapeCloses())
        #else
        self
        #endif
    }

    /// Gives a view presented as a sheet its title on the Mac, for a view that shows its title
    /// on iOS as a `.principal` toolbar item, which a Mac sheet does not draw
    /// (`MacSheetNavigationTitle`). Nil for a view that draws its own title in its content.
    /// Changes nothing on iOS, where the principal item is the title.
    func macSheetNavigationTitle(_ title: String?) -> some View {
        #if os(macOS)
        modifier(MacSheetNavigationTitle(title: title))
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

    /// Makes Escape press a sheet's own close button on the Mac, for a button that is not at
    /// `ToolbarItemPlacement.sheetLeadingBarEdge` (which Escape presses already). Changes
    /// nothing on iOS.
    func macCancelKeyboardShortcut() -> some View {
        #if os(macOS)
        keyboardShortcut(.cancelAction)
        #else
        self
        #endif
    }
}
