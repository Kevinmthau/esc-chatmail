import XCTest
import Combine
@testable import esc_chatmail

@MainActor
final class ComposeViewModelTests: XCTestCase {
    func testAddAttachment_forwardsAttachmentManagerChanges() {
        let viewModel = ComposeViewModel(mode: .newMessage)
        let attachment = Attachment(context: Dependencies.shared.viewContext)
        attachment.id = "local_\(UUID().uuidString)"
        attachment.filename = "photo.jpg"
        attachment.mimeType = "image/jpeg"
        attachment.stateRaw = Attachment.State.queued.rawValue

        let changeExpectation = expectation(description: "ComposeViewModel emits objectWillChange")
        let cancellable = viewModel.objectWillChange.sink { _ in
            changeExpectation.fulfill()
        }
        defer {
            cancellable.cancel()
            viewModel.attachmentManager.clear()
        }

        viewModel.addAttachment(attachment)

        wait(for: [changeExpectation], timeout: 1.0)
        XCTAssertEqual(viewModel.attachments.count, 1)
        XCTAssertEqual(viewModel.attachments.first?.id, attachment.id)
    }

    func testSetupForMode_replyIsIdempotent() {
        let context = Dependencies.shared.viewContext
        let originalUserEmail = AuthSession.shared.userEmail

        let conversation = Conversation(context: context)
        conversation.id = UUID()
        conversation.keyHash = UUID().uuidString
        conversation.type = "personal"

        let me = Person(context: context)
        me.id = UUID()
        me.email = "me@example.com"
        me.displayName = "Me"

        let other = Person(context: context)
        other.id = UUID()
        other.email = "friend@example.com"
        other.displayName = "Friend"

        let meParticipant = ConversationParticipant(context: context)
        meParticipant.id = UUID()
        meParticipant.participantRole = .normal
        meParticipant.person = me
        meParticipant.conversation = conversation

        let otherParticipant = ConversationParticipant(context: context)
        otherParticipant.id = UUID()
        otherParticipant.participantRole = .normal
        otherParticipant.person = other
        otherParticipant.conversation = conversation

        AuthSession.shared.userEmail = me.email
        let viewModel = ComposeViewModel(mode: .reply(conversation, nil))

        viewModel.setupForMode()
        viewModel.setupForMode()

        XCTAssertEqual(viewModel.recipients.map(\.email), ["friend@example.com"])

        AuthSession.shared.userEmail = originalUserEmail
        context.delete(otherParticipant)
        context.delete(meParticipant)
        context.delete(other)
        context.delete(me)
        context.delete(conversation)
        try? context.save()
    }
}
