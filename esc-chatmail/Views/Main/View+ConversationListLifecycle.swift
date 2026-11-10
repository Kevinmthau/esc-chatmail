import SwiftUI
import CoreData

extension View {
    /// What a conversation list does when it comes on screen and when it leaves: the iOS list
    /// (`ConversationListView`) and the Mac sidebar (`MacConversationSidebar`) both attach this,
    /// so the two start and stop the same work.
    ///
    /// The iOS list leaves the screen whenever a chat is pushed over it and comes back when the
    /// chat pops. The Mac sidebar stays beside the open chat and leaves only at sign-out, so there
    /// `onAppear` runs once per sign-in and the view model observes the list the whole time.
    func conversationListLifecycle(
        viewModel: ConversationListViewModel,
        abandonedActions: AbandonedPendingActionsModel,
        viewContext: NSManagedObjectContext,
        authSession: AuthSession
    ) -> some View {
        onAppear {
            // API and Contacts only; safe to call repeatedly (each runs once per
            // launch). WebKit is deliberately warmed solely by the post-init task
            // in esc_chatmailApp.initializeApp(), off the first list layout passes.
            AppPrewarmer.prewarmAll()
            viewModel.onAppear(in: viewContext)
            abandonedActions.refresh()
            // Lookups never prompt on their own, so this is the one deliberate
            // Contacts permission request (no-op after first launch/answer).
            ContactsAuthorizationCoordinator.shared.requestAccessOnFirstAuthenticatedLaunchIfNeeded()
        }
        .onDisappear {
            viewModel.onDisappear(preservePreviewRepair: authSession.canAccessMailbox)
        }
    }
}
