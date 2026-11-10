import CoreGraphics

/// The size a sheet takes on the Mac (`MacSheetChrome`, applied by `View.appSheet`).
///
/// A Mac sheet is as large as its content asks to be, and the content of the app's sheets asks
/// for nothing: each is a `NavigationStack`, a `List`, a `GeometryReader` or a text editor, laid
/// out for an iPhone sheet that fills the screen. Left alone, every one of them came up as an
/// empty strip 80 points tall (measured on macOS 27.2, 2026-11-10).
///
/// The sheet opens at the ideal size, and its window can be resized down to the minimum. The
/// frame gives the height; the width also needs the sheet's sizing fitted to its content
/// (`MacSheetChromeModifier` says why).
/// - A window shorter than the ideal height caps it: the sheet opens 8 points shorter than the
///   window's content, and never below the minimum.
/// - A window narrower than the ideal width does not cap it: the sheet opens wider than its
///   window.
/// - The row of buttons the Mac draws for a sheet's toolbar (Cancel, Send, Done) sits below
///   this size and adds 65 points to the sheet's height. The reader's Done bar is inside it.
///
/// HONEST SCOPE: measured on macOS 27.2 (2026-11-10) with a throwaway program that compiled
/// these `Platform/` files and presented content laid out like the app's sheets on a window
/// placed off the screen, 300 to 1000 points wide and 300 to 900 tall. Not measured: a drag of
/// a sheet's edge. The program read that the sheet's window is resizable and what its minimum
/// size is, and laid the content out at that minimum. Nobody has seen a sheet in the running
/// app, so these sizes are still first guesses (`docs/mac-app-plan.md`).
struct MacSheetSize: Equatable {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat

    /// A short list, such as a chat's participants.
    static let list = MacSheetSize(minWidth: 360, idealWidth: 420, minHeight: 320, idealHeight: 480)
    /// A message being written: New Message and Forward.
    static let compose = MacSheetSize(minWidth: 480, idealWidth: 600, minHeight: 420, idealHeight: 560)
    /// The full email reader, whose mail is usually laid out 600 points wide or more.
    static let reader = MacSheetSize(minWidth: 560, idealWidth: 760, minHeight: 480, idealHeight: 720)
}
