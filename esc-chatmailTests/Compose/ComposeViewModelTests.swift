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
}
