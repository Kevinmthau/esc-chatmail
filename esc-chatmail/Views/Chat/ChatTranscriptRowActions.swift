import SwiftUI
import CoreData

/// What a transcript row asks its chat to do: open a message in the reader, or run a failed
/// send's recovery. One for the chat's life: `ChatMessagesView` holds it as a `StateObject`, made
/// once, as its session is. It publishes nothing; `ObservableObject` is only what lets the view
/// keep it.
///
/// The rows' closures call this and capture nothing else of the chat. A bubble is `Equatable`
/// on its value inputs (`MessageBubbleInputs`), so a row whose inputs did not change keeps the
/// closures of an older pass of the transcript; through this object they still act on the
/// chat as it is when they are called. Everything it holds lives as long as the chat: the view
/// model, the reply field's focus (a `FocusState` binding and the Mac's bridge, both the chat
/// screen's own), and the presenter's reader opener, which reads the chat's view model when
/// called.
@MainActor
final class ChatTranscriptRowActions: ObservableObject {
    private let viewModel: ChatViewModel
    private let focus: ChatComposerFocus
    private let openFullMessageInReader: (NSManagedObjectID, EmailReaderOpenSource) -> Void

    init(
        viewModel: ChatViewModel,
        focus: ChatComposerFocus,
        openFullMessage: @escaping (NSManagedObjectID, EmailReaderOpenSource) -> Void
    ) {
        self.viewModel = viewModel
        self.focus = focus
        self.openFullMessageInReader = openFullMessage
    }

    func openFullMessage(_ messageObjectID: NSManagedObjectID, source: EmailReaderOpenSource) {
        openFullMessageInReader(messageObjectID, source)
    }

    /// The one route from a failed-send affordance (long-press menu, or the bubble's recovery
    /// dialog) into the view model's existing recovery paths. Neither adds a send path: Edit and
    /// Resend only refills the composer, and Check Delivery only re-reads Gmail.
    func performSendRecovery(
        _ action: FailedSendRecoveryPolicy.Action,
        messageObjectID: NSManagedObjectID
    ) {
        switch action {
        case .editAndResend:
            if viewModel.editFailedReply(messageObjectID: messageObjectID), viewModel.destination == nil {
                focus.wrappedValue = true
            }
        case .checkDelivery:
            viewModel.checkReplyDelivery(messageObjectID: messageObjectID)
        }
    }
}
