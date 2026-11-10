import CoreGraphics

/// The size a sheet takes on the Mac (`View.macSheetSize(_:)`).
///
/// A Mac sheet is as large as its content asks to be, and the content of the app's sheets asks
/// for nothing: each is a `NavigationStack`, a `List`, a `GeometryReader` or a text editor, laid
/// out for an iPhone sheet that fills the screen. Left alone, every one of them came up as an
/// empty strip 80 points tall (measured on macOS 27.2, 2026-11-10). The ideal size is what the
/// sheet opens at, capped by the height of the window it is attached to.
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
