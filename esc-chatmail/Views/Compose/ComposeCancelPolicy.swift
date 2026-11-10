import Foundation

/// Decides what Cancel does in a compose sheet (`ComposeView`), and whether the sheet may be
/// dismissed without it.
///
/// On iOS, Cancel is always a tap on the button and discards at once, as it always has. On the
/// Mac, Escape is Cancel, and Escape is also the key people press to close an autocomplete
/// list or leave a field. Measured on macOS 27.2 (2026-11-10), with a throwaway program:
///
/// - A sheet whose text field has the focus is closed by Escape itself. No button is pressed,
///   so nothing can ask first, and the compose sheet's recipient field takes the focus as it
///   opens. Closing discards the draft.
/// - With interactive dismissal disabled, Escape presses the sheet's `.cancelAction` button
///   instead, and does nothing when there is none.
enum ComposeCancelPolicy {
    enum Action: Equatable {
        /// Discard the draft and close the sheet.
        case discard
        /// Ask first. The draft is kept unless the user then chooses to discard it.
        case confirmDiscard
    }

    /// - iOS → discard, whatever was typed: unchanged.
    /// - The Mac with nothing of the user's in the draft → discard: there is nothing to lose.
    /// - The Mac with the user's edits in the draft (`ComposeViewModel.hasUserEdits`) → ask.
    static func action(platform: AppPlatform, hasUserEdits: Bool) -> Action {
        platform == .macOS && hasUserEdits ? .confirmDiscard : .discard
    }

    /// - A send in flight → disabled on both platforms, as before the Mac port.
    /// - The Mac → always disabled, so Escape reaches the Cancel button and `action` decides,
    ///   instead of the sheet closing by itself.
    static func disablesInteractiveDismiss(platform: AppPlatform, isSending: Bool) -> Bool {
        isSending || platform == .macOS
    }
}
