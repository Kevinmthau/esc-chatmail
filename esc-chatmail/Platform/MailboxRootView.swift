import SwiftUI

/// The signed-in mailbox, in each platform's own shape.
///
/// iOS: the conversation list in a `NavigationStack`, which pushes a chat over it. Unchanged from
/// before the Mac's split view; the transcript's anchoring and reveal were tuned inside it.
///
/// Mac: `MacMailboxView`, a sidebar of conversations with the selected chat beside it, as in
/// Messages (`docs/mac-imessage-ui-plan.md`).
struct MailboxRootView: View {
    let dependencies: Dependencies

    var body: some View {
        #if os(macOS)
        MacMailboxView(deps: dependencies)
        #else
        NavigationStack {
            ConversationListView(deps: dependencies)
        }
        #endif
    }
}
