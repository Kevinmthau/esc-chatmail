#if os(macOS)
import SwiftUI
import CoreData

/// The Mac window's sidebar: the conversation list, its search field and its filter menu
/// (`MacMailboxView` owns it; `docs/mac-imessage-ui-plan.md`, PR 1).
///
/// It is the Mac's counterpart of `ConversationListView`, not a second mode of it. That list's
/// body is iOS chrome: a bottom bar, a Select mode with checkboxes, a tap gesture that would
/// swallow the click a selection needs, and a `navigationDestination`. What the two share is what
/// has to stay the same: the view model (so live updates still come from its `objectsDidChange`
/// pipeline, never a `@FetchRequest`), the row view, the banners, the filter menu and the
/// lifecycle work.
///
/// The selection is the list's own (`List(selection:)`): a click selects, Shift-click and
/// Command-click extend, and the arrow keys move it. One selected row is the open chat
/// (`MacSidebarSelectionPolicy`).
///
/// How a selected row looks is the sidebar's, not the list's: the row sits on a fill the sidebar
/// draws, in colors to match, so the open conversation stays in the accent color while the caret
/// is in the reply field (`MacSidebarRowSelectionPolicy`).
struct MacConversationSidebar: View {
    @ObservedObject var viewModel: ConversationListViewModel
    @ObservedObject var abandonedActions: AbandonedPendingActionsModel
    /// Observed only for `isBlockedByInsufficientStorage`, as in `ConversationListView`.
    @ObservedObject var syncEngine: SyncEngine
    @Binding var selection: Set<NSManagedObjectID>
    let currentUserEmail: String
    let participantLoader: ParticipantLoader
    let viewContext: NSManagedObjectContext
    /// Archive and Report Spam for rows of this list. `MacMailboxView` runs them, because they
    /// also move the selection.
    let onArchive: @MainActor (Set<NSManagedObjectID>) -> Void
    let onReportSpam: @MainActor (Set<NSManagedObjectID>) -> Void
    let onNewMessage: @MainActor () -> Void

    @FocusState private var isSearchFieldFocused: Bool
    /// Whether this window is the one the user is working in (`WindowAppearsActive` says what
    /// that means on the Mac). A selected row is gray in a window that is not.
    ///
    /// Read from the environment here, not through a `WindowAppearsActive` property as in
    /// `ChatView`. `MacMailboxView` builds this view with its memberwise initializer, and
    /// `private var x = WindowAppearsActive()` is a parameter of that initializer under Swift
    /// 6.2 (Xcode 26, which CI builds with), which makes the initializer private. A private
    /// property with a property wrapper is not a parameter under either compiler. Swift 6.4
    /// (Xcode 27) leaves the plain property out too, so that spelling builds on this Mac and
    /// fails only CI's "Build (macOS)".
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // Empty unless several rows are selected, and then one pass over the rows.
        let selectionJoins = MacSidebarRowSelectionPolicy.joins(
            orderedIDs: viewModel.filteredConversationItems.lazy.map(\.id),
            selection: selection
        )
        List(selection: $selection) {
            if syncEngine.isBlockedByInsufficientStorage {
                InsufficientStorageBanner(onTryAgain: {
                    Task { await viewModel.performSync() }
                })
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden, edges: .top)
                // A banner is not a conversation: it must not join the selection, which
                // decides the open chat.
                .selectionDisabled()
            }
            if let summary = abandonedActions.summary {
                AbandonedPendingActionsBanner(
                    summary: summary,
                    onRetry: abandonedActions.retryAll,
                    onDismiss: abandonedActions.dismissAll
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden, edges: .top)
                .selectionDisabled()
            }
            // The row's identity, and so its selection value, is the conversation's object ID
            // (`ConversationListItem.id`).
            ForEach(viewModel.filteredConversationItems) { item in
                let selectionFill = MacSidebarRowSelectionPolicy.fill(
                    isSelected: selection.contains(item.id),
                    windowAppearsActive: appearsActive
                )
                ConversationRowView(
                    snapshot: item.snapshot,
                    conversationObjectID: item.id,
                    conversationContext: viewContext,
                    currentUserEmail: currentUserEmail,
                    participantLoader: participantLoader,
                    metrics: .mac,
                    palette: MacSidebarRowSelectionPolicy.palette(on: selectionFill)
                )
                // The fill and the palette above come from one decision and go together:
                // without this the row's white text sits on the list's own gray selection.
                .listRowBackground(
                    MacSidebarRowSelectionBackground(
                        fill: selectionFill,
                        joins: selectionJoins[item.id] ?? .none
                    )
                )
                .onAppear {
                    viewModel.loadMoreIfNeeded(currentItem: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onArchive([item.id])
                    } label: {
                        SwiftUI.Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        viewModel.toggleConversationReadState(withID: item.id)
                    } label: {
                        if item.snapshot.inboxUnreadCount > 0 {
                            SwiftUI.Label("Read", systemImage: "envelope.open")
                        } else {
                            SwiftUI.Label("Unread", systemImage: "envelope.badge")
                        }
                    }
                    .tint(.blue)
                }
            }
        }
        // The style that draws Messages' list on the Mac: an inset, rounded selection and
        // separators that start at the text. `.sidebar` draws neither (measured off screen on
        // macOS 27.2; `docs/mac-imessage-ui-plan.md`, "Spike results").
        .listStyle(.inset)
        .animation(nil, value: viewModel.filteredConversationItems.count)
        // The menu's rows are the ones right-clicked: the whole selection when the click is
        // inside it, otherwise just the clicked row, which the selection then does not follow.
        .contextMenu(forSelectionType: NSManagedObjectID.self) { conversationIDs in
            contextMenuItems(for: conversationIDs)
        }
        // Delete archives the selected rows, as it removes the selected rows of any Mac list.
        // It reaches here only while the list has the keyboard focus, not while a text field
        // does.
        .onDeleteCommand {
            onArchive(selection)
        }
        .searchable(text: $viewModel.searchText, placement: .sidebar, prompt: Text("Search"))
        .searchFocused($isSearchFieldFocused)
        .toolbar {
            // Pushes the filter menu to the sidebar's trailing edge, where Messages has it.
            // Without it the item sits right after the window's close, minimize and zoom
            // buttons.
            ToolbarSpacer(.flexible)
            ToolbarItem {
                ConversationFilterMenu(currentFilter: viewModel.currentFilter) { filter in
                    viewModel.currentFilter = filter
                }
                // A count of zero draws no badge.
                .badge(MacSidebarFilterBadgePolicy.badgeCount(for: viewModel.currentFilter))
            }
        }
        .focusedSceneValue(
            \.mailboxMenuActions,
            MailboxMenuActions(
                newMessage: onNewMessage,
                search: { isSearchFieldFocused = true },
                sync: { Task { await viewModel.performSync() } }
            )
        )
    }

    @ViewBuilder
    private func contextMenuItems(for conversationIDs: Set<NSManagedObjectID>) -> some View {
        // Empty for a right-click on a banner or on the space below the last row.
        if !conversationIDs.isEmpty {
            Button("Archive", systemImage: "archivebox") {
                onArchive(conversationIDs)
            }
            if conversationIDs.count == 1,
               let conversationID = conversationIDs.first,
               let item = viewModel.filteredConversationItems.first(where: { $0.id == conversationID }) {
                Button(
                    item.snapshot.inboxUnreadCount > 0 ? "Mark as Read" : "Mark as Unread",
                    systemImage: item.snapshot.inboxUnreadCount > 0 ? "envelope.open" : "envelope.badge"
                ) {
                    viewModel.toggleConversationReadState(withID: conversationID)
                }
            }
            Button("Report Spam", systemImage: "exclamationmark.triangle") {
                onReportSpam(conversationIDs)
            }
        }
    }
}
#endif
