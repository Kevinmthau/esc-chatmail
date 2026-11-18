import SwiftUI

/// A conversation row's trailing swipe, for the iPhone's list (`ConversationListView`) and the
/// Mac's sidebar (`MacConversationSidebar`). Both attach it, so the two swipes are one
/// definition; what it offers and in which order is `ConversationRowSwipePolicy.trailingActions`.
extension View {
    /// The policy's trailing actions, the first at the row's edge, where a full swipe performs
    /// it. Nothing else may go in this swipe: the order is the behavior, and it is decided in the
    /// policy (`ConversationListSwipeActionsSourceTests` pins that the swipe is the policy's
    /// list and nothing more; `ConversationRowTrailingSwipeActionsMacTests` reads the order back
    /// from the table behind a real list on the Mac).
    ///
    /// - Parameters:
    ///   - isEnabled: False offers nothing (`ConversationRowSwipePolicy.trailingActions`).
    ///   - onReportSpam: Asks; it must not report (`conversationSpamConfirmation` does, once
    ///     the question is answered).
    func conversationRowTrailingSwipeActions(
        isEnabled: Bool,
        onArchive: @escaping @MainActor () -> Void,
        onReportSpam: @escaping @MainActor () -> Void
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            ForEach(ConversationRowSwipePolicy.trailingActions(isEnabled: isEnabled), id: \.self) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    switch action {
                    case .archive: onArchive()
                    case .reportSpam: onReportSpam()
                    }
                } label: {
                    SwiftUI.Label(action.title, systemImage: action.systemImage)
                }
                .tint(action.tint)
            }
        }
    }
}

private extension ConversationRowSwipePolicy.TrailingAction {
    var tint: Color {
        switch self {
        case .archive: return .blue
        case .reportSpam: return .orange
        }
    }
}
