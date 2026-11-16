import SwiftUI

extension View {
    /// Runs `action` each time this content becomes what a sheet shows: when it appears, and
    /// when the Mac gives the sheet's window to another item (`onMacSheetItemHandOver`).
    /// `appSheet(item:)` puts it on its content for `onItemShown`, which is how a presenter
    /// keeps track of the item on screen (`ChatView.presentedSheetDestination`).
    ///
    /// The two reports are one modifier with one action so that a presenter cannot have the
    /// first without the second, which is the fault `onMacSheetItemHandOver` describes. On iOS
    /// it is `onAppear` and nothing else, as the chat's sheet content had before the Mac port.
    func onSheetItemShown<ID: Equatable>(
        _ id: ID,
        perform action: @escaping () -> Void
    ) -> some View {
        onAppear(perform: action)
            .onMacSheetItemHandOver(to: id, perform: action)
    }

    /// Runs `action` when the Mac gives the sheet this content is in to another item. The
    /// Mac's half of `onSheetItemShown`, which is its only caller.
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
    /// Participants' Create New Contact was such a replacement in the app, where Contacts
    /// access is already given: the row's menu action hides Participants and starts a task
    /// that sets the contact (`ChatContactManager.createNewContact`), and the unified log of
    /// the run that showed the fault has the Participants sheet's window still attached after
    /// the menu action, with no sheet ended and none begun. So both changes reached SwiftUI in
    /// one update there. Why is not known, and no other order may be counted on: in the
    /// throwaway program a task started beside the first change, from a timer and not from a
    /// menu's action, set the contact only after SwiftUI's update. The sheet had ended by then
    /// (`onDismiss` runs in the update that takes the item away, and the closing animation
    /// then holds the main thread about a quarter of a second) and a new one began. The
    /// program showed the hand-over only where it made both changes in one turn. Reordering
    /// that task is therefore no fix, and this must hold for either order.
    ///
    /// `ChatView` tracked the sheet on screen by that `onAppear` alone, so after the hand-over
    /// the chat still took Participants for the sheet on screen, read every dismissal of New
    /// Contact as the end of a sheet being replaced (`ChatSheetDismissalPolicy`), and cleared
    /// nothing: Open in Contacts opened Contacts and left the sheet up, and Cancel goes the
    /// same way, so nothing in the window could close it (build 562, 2026-11-15).
    ///
    /// It does nothing on iOS. There the sheet whose item changes is dismissed, `onDismiss`
    /// runs, and the next item's content appears in a new sheet with its `onAppear`. The
    /// outgoing sheet's content can be given the new item for a moment on the way. On iOS 27.0
    /// that is after `onDismiss`, where the action would be harmless; before `onDismiss` it
    /// would make the presenter take the incoming item for the one dismissed and clear it. The
    /// floor is iOS 17.6, which could not be measured, so iOS is left as it was.
    ///
    /// Measured 2026-11-15 in a throwaway program with the chat's sheet bookkeeping, on macOS
    /// 27.2.1 and the iOS 27.0 simulator, and again on the Mac the same day with the program
    /// presenting through `appSheet(item:)` itself, Mac chrome included, and deciding with
    /// `ChatSheetDismissalPolicy`: with both changes in one turn `onItemShown` ran once for
    /// each item and the sheet closed, and with the record kept by an `onAppear` on the content
    /// it stayed up. The fix has not been seen in the app.
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
