import SwiftUI

extension View {
    /// Asks, on the Mac, before a compose sheet discards what the user typed
    /// (`ComposeCancelPolicy`). Changes nothing on iOS, where Cancel discards at once and
    /// `isPresented` is never set.
    ///
    /// Escape presses Keep Editing. Discard is destructive and is no key's default, so it takes
    /// a click (measured on macOS 27.2, 2026-11-10: Return pressed neither button).
    func macDiscardDraftConfirmation(isPresented: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        #if os(macOS)
        alert("Discard This Message?", isPresented: isPresented) {
            Button("Discard", role: .destructive, action: onDiscard)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your draft will not be saved.")
        }
        #else
        self
        #endif
    }
}
