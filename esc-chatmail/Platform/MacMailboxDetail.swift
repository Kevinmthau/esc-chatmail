#if os(macOS)
import SwiftUI
import CoreData

/// The Mac window's chat column: the selected conversation's chat, a placeholder when nothing is
/// selected, or the batch actions when several rows are (`MacSidebarSelectionPolicy.detail`).
///
/// `Equatable` on the selection alone, and shown through `.equatable()`. `MacMailboxView`'s body
/// runs again on every change the list's view model publishes: a keystroke in the search field,
/// every sync that touches the list. None of that changes what this column shows, and without the
/// check each one would re-evaluate the open chat's transcript. Everything else stored here is
/// either fixed for the life of the mailbox view (the context, the dependency bundle) or a
/// closure that reads its state when it is called, so skipping an update never leaves a stale
/// value behind.
struct MacMailboxDetail: View, Equatable {
    let selection: Set<NSManagedObjectID>
    let viewContext: NSManagedObjectContext
    let chatDependencies: ChatDependencies
    let makeForwardComposeView: @MainActor (ComposeForwardModeContext) -> ComposeView
    /// The open chat closed itself (`ChatView.onExit`).
    let onExitChat: @MainActor (NSManagedObjectID) -> Void
    let onArchive: @MainActor (Set<NSManagedObjectID>) -> Void
    let onReportSpam: @MainActor (Set<NSManagedObjectID>) -> Void

    nonisolated static func == (lhs: MacMailboxDetail, rhs: MacMailboxDetail) -> Bool {
        lhs.selection == rhs.selection
    }

    var body: some View {
        switch MacSidebarSelectionPolicy.detail(for: selection) {
        case .placeholder:
            placeholder
        case .conversation(let conversationID):
            if let conversation = try? viewContext.existingObject(with: conversationID) as? Conversation {
                ChatView(
                    conversation: conversation,
                    chatDependencies: chatDependencies,
                    // Messages' header: the avatar in the toolbar, the name in a capsule
                    // under it (`ChatHeaderPolicy`).
                    headerStyle: .avatarOverNameCapsule(.mac),
                    // Messages' transcript: tailed bubbles, time lines between groups of
                    // messages (`MessageBubbleStyle.mac`).
                    bubbleStyle: .mac,
                    makeForwardComposeView: makeForwardComposeView,
                    // Never nil here: without it the chat would close itself with `dismiss`,
                    // which in this column closes the window (`ChatView.exitChat`).
                    onExit: { onExitChat(conversationID) }
                )
                // A different conversation is a different chat: its own view model, transcript
                // session and composer, as each push builds on iOS.
                .id(conversationID)
            } else {
                // The row was deleted under the selection; the next list change drops it
                // (`MacSidebarSelectionPolicy.selectionAfterListChange`).
                placeholder
            }
        case .multiple(let count):
            MacMultipleSelectionView(
                count: count,
                onArchive: { onArchive(selection) },
                onReportSpam: { onReportSpam(selection) }
            )
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            SwiftUI.Label("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
        }
    }
}
#endif
