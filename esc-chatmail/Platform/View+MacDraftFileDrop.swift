import SwiftUI

extension View {
    /// Makes a Mac chat take files dropped on it as attachments of its reply: a drop view
    /// behind the whole chat (`MacDraftFileDropView`), which the reply field and the email
    /// cards in front of it hand file drags to. Nothing on iOS.
    ///
    /// - Parameters:
    ///   - acceptsFiles: Whether the reply can take files now, asked as a drag moves over the
    ///     chat and again at the drop.
    ///   - onDropFiles: The dropped files. Returns whether the drop was taken.
    func macDraftFileDrop(
        acceptsFiles: @escaping @MainActor () -> Bool,
        onDropFiles: @escaping @MainActor ([URL]) -> Bool
    ) -> some View {
        #if os(macOS)
        background {
            MacDraftFileDropTarget(acceptsFiles: acceptsFiles, onDropFiles: onDropFiles)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }

    /// Makes a Mac sheet take files dropped anywhere on it, or refuse them everywhere on it:
    /// the same drop view as a chat's (`MacDraftFileDropView`), laid over the sheet's content
    /// and not behind it. Nothing on iOS.
    ///
    /// In front, because a sheet's fields are SwiftUI's own and cannot hand a drag on as the
    /// chat's reply field does (`MacFileDropForwarder`). Measured in the sandboxed test host on
    /// macOS 27.2 (2026-11-13), by asking the window which view it would give a file drag to
    /// over a `TextField`, a `TextField` with a vertical axis and a `TextEditor`:
    /// - **With the drop view behind them,** a text field that has the caret took the drag
    ///   itself, through its field editor, and a text editor took it with or without the
    ///   caret. Each types the dropped file's path.
    /// - **With the drop view in front,** every file drag over the sheet went to the drop view,
    ///   in a navigation stack too. A drag of text still went to the field under it, because
    ///   the drop view is registered for files only.
    ///
    /// The drop view takes no clicks, and two things see to it. Its own `hitTest` is nil. And
    /// it is left out of SwiftUI's hit testing (`allowsHitTesting(false)`), which does not
    /// stop a drag reaching it and, measured with the view's `hitTest` made to answer, hides
    /// it from AppKit's hit test too: a click over a field found the field with either one
    /// in place, and the drop view only with both removed. Keep both. HONEST SCOPE: that a
    /// SwiftUI button under it is still pressed was not measured. A window that is never
    /// shown presses no SwiftUI button, with or without the drop view
    /// (`docs/mac-app-plan.md`, "Files").
    ///
    /// - Parameters:
    ///   - acceptsFiles: Whether the sheet can take files now. False refuses every file drag
    ///     over it, which also keeps a path from being typed into its fields.
    ///   - onDropFiles: The dropped files. Returns whether the drop was taken.
    func macDraftFileDropOverlay(
        acceptsFiles: @escaping @MainActor () -> Bool,
        onDropFiles: @escaping @MainActor ([URL]) -> Bool
    ) -> some View {
        #if os(macOS)
        overlay {
            MacDraftFileDropTarget(acceptsFiles: acceptsFiles, onDropFiles: onDropFiles)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}
