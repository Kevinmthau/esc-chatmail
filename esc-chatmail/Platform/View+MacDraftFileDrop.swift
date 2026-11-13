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
}
