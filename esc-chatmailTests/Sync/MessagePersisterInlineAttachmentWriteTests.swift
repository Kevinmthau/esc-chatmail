import XCTest
import CoreData
@testable import esc_chatmail

/// A synthesized inline part whose bytes cannot be written when its message is stored
/// (architecture review 2026-11, attachments-storage-disk#5). Fixtures and the persister run on
/// a main-queue context, as in `MessagePersisterUpdateTests`.
@MainActor
final class MessagePersisterInlineAttachmentWriteTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var persister: MessagePersister!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.makeMainQueueViewContext()
        persister = MessagePersister(photoPrefetcher: { _ in })
        AttachmentPaths.setupDirectories()
    }

    override func tearDown() {
        persister = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    // Revert-check: the deleted `context.delete(attachment)` in
    // `MessagePersister.createAttachment`. Put it back and the message is stored with no row for
    // its inline image, which nothing recreates: the recovery needs the row.
    func testCreateNewMessage_inlinePartThatCannotBeWritten_keepsAQueuedRowWithNoFile() async throws {
        let messageID = "inline-write-failure-\(UUID().uuidString)"
        let attachmentID = "local_inline_write_failure"
        let inlineImageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="))
        // A real failed write: a directory, with a file in it, where the part would go.
        let blockedURL = try XCTUnwrap(AttachmentPaths.fullURL(for: AttachmentPaths.originalPath(
            messageId: messageID,
            attachmentId: attachmentID,
            ext: "png"
        )))
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
        try Data("in the way".utf8).write(to: blockedURL.appendingPathComponent("occupant"))
        defer { try? FileManager.default.removeItem(at: blockedURL) }

        var headers = ProcessedHeaders()
        headers.subject = "Inline attachment"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false
        let processedMessage = ProcessedMessage(
            id: messageID,
            gmThreadId: "thread-\(messageID)",
            snippet: "See image",
            cleanedSnippet: "See image",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "See image",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: true,
            attachmentInfo: [
                AttachmentInfo(
                    id: attachmentID,
                    filename: "inline.png",
                    mimeType: "image/png",
                    size: inlineImageData.count,
                    contentId: "inline-write-failure",
                    inlineData: inlineImageData
                )
            ]
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageID)
        request.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(request).first)
        XCTAssertEqual(savedMessage.attachmentsArray.count, 1)
        let attachment = try XCTUnwrap(savedMessage.attachmentsArray.first)
        XCTAssertEqual(attachment.id, attachmentID)
        XCTAssertEqual(attachment.state, .queued)
        XCTAssertNil(attachment.localURL)
        XCTAssertNil(attachment.previewURL)
        XCTAssertEqual(attachment.contentId, "inline-write-failure")
    }
}
