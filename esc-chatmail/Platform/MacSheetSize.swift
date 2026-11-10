import CoreGraphics

/// The size a sheet takes on the Mac (`MacSheetChrome`, applied by `View.appSheet`).
///
/// A Mac sheet is as large as its content asks to be, and the content of the app's sheets asks
/// for nothing: each is a `NavigationStack`, a `List`, a `GeometryReader` or a text editor, laid
/// out for an iPhone sheet that fills the screen. Left alone, every one of them came up as an
/// empty strip 80 points tall (measured on macOS 27.2, 2026-11-10).
///
/// The width is one number and the height is a minimum and an ideal, because the Mac sizes a
/// sheet's two axes differently: it offers the content 470 points of width and leaves the height
/// to it (`MacSheetChromeModifier` says what that does to a width given as a range).
/// - The sheet opens `width` wide, whatever the width of the window it hangs from, so it can be
///   wider than that window.
/// - It opens `idealHeight` tall. A window shorter than that caps it: the sheet opens 40 points
///   shorter than the window's content, and never below `minHeight`.
/// - The row of buttons the Mac draws for a sheet's toolbar (Cancel, Send, Done) sits below
///   this size and adds 65 points to the sheet's height. The reader's Done bar is inside it.
/// - The sheet's window cannot be resized.
///
/// HONEST SCOPE: measured on macOS 27.2 (2026-11-10) with a throwaway program that compiled
/// these `Platform/` files and presented content laid out like the app's sheets on a window
/// placed off the screen, 300 to 1000 points wide and 300 to 900 tall. Nobody has seen a sheet
/// in the running app, so these sizes are still first guesses (`docs/mac-app-plan.md`).
struct MacSheetSize: Equatable {
    let width: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat

    /// A short list, such as a chat's participants.
    static let list = MacSheetSize(width: 420, minHeight: 320, idealHeight: 480)
    /// A message being written: New Message and Forward.
    static let compose = MacSheetSize(width: 600, minHeight: 420, idealHeight: 560)
    /// The full email reader, whose mail is usually laid out 600 points wide or more.
    static let reader = MacSheetSize(width: 760, minHeight: 480, idealHeight: 720)
}
