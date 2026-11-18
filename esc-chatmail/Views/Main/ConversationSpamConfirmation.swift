import SwiftUI
import CoreData

/// Asks before a row's swipe reports its conversation as spam, on the iPhone's list and the
/// Mac's sidebar alike (`View.conversationSpamConfirmation`). The rules are
/// `ConversationRowSwipePolicy`'s; this applies them.
///
/// Three things about it go together:
/// - It names the conversation as its row does (`ConversationRowSwipePolicy.questionTitle`,
///   from `ConversationRowView.displayedName`), because once the swipe has closed nothing else
///   on screen says which row asked. The title keeps the name of the question on screen while
///   it is taken down (`shownRequest`): read from the cleared request, it would turn generic
///   for any redraw during the question's exit.
/// - It is taken down, unanswered, when its row is not in the list, whether the row left
///   while it was up or was already gone in the update that raised it
///   (`ConversationRowSwipePolicy.withdrawsQuestion`), and an answer reports only a
///   conversation the list still shows when it runs, so both lists do the same with a row that
///   went away.
/// - The answer reports only once the question is gone, a main-actor turn later
///   (`ConversationRowSwipePolicy.conversationToReport`), as `MessageBubble`'s send-recovery
///   question does, so the report's own changes come after the question's teardown. On the Mac,
///   where the swiped row was the open chat, the report moves the selection to the next chat;
///   whether that chat focuses its reply field is its own rule (`focusesFieldWhenChatAppears`):
///   a question answered with a key reads as a key press, as Delete on a row does, and leaves
///   the focus where it was. That one turn is enough for the sheet's teardown is not measured.
///
/// Attached to the list, not the row: a row can be drawn again under the question (a sync
/// publish, and on the Mac the reload of the list's table that
/// `MacSidebarListSelectionGuardView` makes), and a question kept by the row could go with it.
struct ConversationSpamConfirmation: ViewModifier {
    /// The row's Report Spam waiting for its answer; nil while none is. The answer clears it.
    @Binding var request: ConversationRowSwipePolicy.SpamReportRequest?
    /// Whether the list showed the requested conversation when the list was last drawn.
    let requestIsListed: Bool
    /// Whether the list shows a conversation now: asked when a question comes up, and again
    /// when its answer runs, after the question is gone.
    let isListed: @MainActor (NSManagedObjectID) -> Bool
    let onConfirm: @MainActor (NSManagedObjectID) -> Void

    /// The answered request, held until the question is gone.
    @State private var answered: ConversationRowSwipePolicy.SpamReportRequest?
    /// The last request the question was raised for, kept after `request` is cleared so the
    /// title does not change while the question is taken down.
    @State private var shownRequest: ConversationRowSwipePolicy.SpamReportRequest?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                ConversationRowSwipePolicy.questionTitle(for: request ?? shownRequest),
                isPresented: Binding(
                    get: { request != nil },
                    set: { isPresented in
                        if !isPresented {
                            request = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: request
            ) { pending in
                Button("Report Spam", role: .destructive) {
                    answered = pending
                    reportIfQuestionIsGone()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(ConversationRowSwipePolicy.questionMessage)
            }
            .onChange(of: request) { _, newRequest in
                if let newRequest {
                    shownRequest = newRequest
                    if ConversationRowSwipePolicy.withdrawsQuestion(
                        isQuestionPresented: true,
                        conversationIsListed: isListed(newRequest.conversationID)
                    ) {
                        request = nil
                        return
                    }
                }
                reportIfQuestionIsGone()
            }
            .onChange(of: requestIsListed) { _, isListedNow in
                if ConversationRowSwipePolicy.withdrawsQuestion(
                    isQuestionPresented: request != nil,
                    conversationIsListed: isListedNow
                ) {
                    request = nil
                }
            }
    }

    /// Called from both the answer and the question's leaving; whichever comes second reports,
    /// once, a main-actor turn later.
    private func reportIfQuestionIsGone() {
        guard let conversationID = ConversationRowSwipePolicy.conversationToReport(
            answered: answered,
            isQuestionPresented: request != nil
        ) else {
            return
        }
        answered = nil
        let isListed = isListed
        let onConfirm = onConfirm
        Task { @MainActor in
            guard isListed(conversationID) else { return }
            onConfirm(conversationID)
        }
    }
}

extension View {
    /// Asks before a row's swipe reports its conversation as spam (`ConversationSpamConfirmation`).
    ///
    /// - Parameters:
    ///   - request: Set by the row's swipe (`conversationRowTrailingSwipeActions`'s
    ///     `onReportSpam`); the question is up while it is not nil.
    ///   - isListed: Whether the list shows a conversation, read from the list's own rows.
    ///     Read while a question is up, and once more when its answer runs.
    ///   - onConfirm: Reports the conversation, a turn after the question is gone and only if
    ///     the list still shows it.
    func conversationSpamConfirmation(
        for request: Binding<ConversationRowSwipePolicy.SpamReportRequest?>,
        isListed: @escaping @MainActor (NSManagedObjectID) -> Bool,
        onConfirm: @escaping @MainActor (NSManagedObjectID) -> Void
    ) -> some View {
        modifier(
            ConversationSpamConfirmation(
                request: request,
                requestIsListed: request.wrappedValue.map { isListed($0.conversationID) } ?? false,
                isListed: isListed,
                onConfirm: onConfirm
            )
        )
    }
}
