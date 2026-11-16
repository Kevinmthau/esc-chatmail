import SwiftUI

extension View {
    /// Runs `action` when the Mac gives the sheet this content is in to another item. For the
    /// content of an `appSheet(item:)` whose presenter keeps track of the item on screen
    /// (`ChatView.presentedSheetDestination`).
    ///
    /// Where a sheet's item is replaced by another before SwiftUI's next update, the Mac does
    /// not end the sheet and begin another. It keeps the sheet's window and draws the next
    /// item's content in it (`MacSheetChromeModifier`), and tells the presenter nothing:
    /// `onDismiss` is not called, and an `onAppear` on the view the content closure returns
    /// does not run a second time, though the views inside it disappear and appear. Only the
    /// closure's argument changes, which is what this watches. Where the item is nil for an
    /// update in between, the sheet ends and a new one begins, with `onDismiss` and `onAppear`,
    /// and this does not run.
    ///
    /// Participants' Create New Contact is such a replacement where Contacts access is already
    /// given: the row's menu action hides Participants and the task it starts sets the contact
    /// before the next update (`ChatContactManager.createNewContact`). `ChatView` tracked the
    /// sheet on screen by that `onAppear` alone, so after it the chat still took Participants
    /// for the sheet on screen, read every dismissal of New Contact as the end of a sheet being
    /// replaced, and cleared nothing: Open in Contacts opened Contacts and left the sheet up,
    /// and Cancel goes the same way, so nothing in the window could close it (build 562,
    /// 2026-11-15).
    ///
    /// It does nothing on iOS. There the sheet whose item changes is dismissed, `onDismiss`
    /// runs, and the next item's content appears in a new sheet with its `onAppear`. The
    /// outgoing sheet's content can be given the new item for a moment on the way. On iOS 27.0
    /// that is after `onDismiss`, where the action would be harmless; before `onDismiss` it
    /// would make the presenter take the incoming item for the one dismissed and clear it. The
    /// floor is iOS 17.6, which could not be measured, so iOS is left as it was.
    ///
    /// Measured 2026-11-15 in a throwaway program with the chat's sheet bookkeeping, on macOS
    /// 27.2.1 and the iOS 27.0 simulator. The unified log of the run that showed the fault has
    /// the Participants sheet's window still attached after the menu action, with no sheet
    /// ended and none begun. The fix has not been seen in the app.
    func onMacSheetItemHandOver<ID: Equatable>(
        to id: ID,
        perform action: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        onChange(of: id) { action() }
        #else
        self
        #endif
    }
}
