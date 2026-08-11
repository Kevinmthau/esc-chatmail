import XCTest
@testable import esc_chatmail

final class AttachmentPathsTests: XCTestCase {
    func testRemotePathsScopeReusedAttachmentIDToMessage() {
        let first = AttachmentPaths.originalPath(
            messageId: "message-one",
            attachmentId: "shared-attachment",
            ext: "dat"
        )
        let second = AttachmentPaths.originalPath(
            messageId: "message-two",
            attachmentId: "shared-attachment",
            ext: "dat"
        )

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(
            AttachmentPaths.usesRemoteIdentity(
                first,
                messageId: "message-one",
                attachmentId: "shared-attachment"
            )
        )
        XCTAssertFalse(
            AttachmentPaths.usesRemoteIdentity(
                first,
                messageId: "message-two",
                attachmentId: "shared-attachment"
            )
        )
    }

    func testLegacyIDOnlyPathRemainsAvailableButIsNotCompositeRemoteStorage() {
        let legacyPath = AttachmentPaths.originalPath(
            idOrUUID: "shared-attachment",
            ext: "dat"
        )

        XCTAssertEqual(legacyPath, "Attachments/shared-attachment.dat")
        XCTAssertFalse(
            AttachmentPaths.usesRemoteIdentity(
                legacyPath,
                messageId: "message-one",
                attachmentId: "shared-attachment"
            )
        )
    }

    func testReadableStoragePathRejectsLegacyRemotePathAndMissingMessageIdentity() {
        let attachmentID = "shared-attachment"
        let messageID = "message-one"
        let legacyPath = AttachmentPaths.previewPath(idOrUUID: attachmentID)
        let currentPath = AttachmentPaths.previewPath(
            messageId: messageID,
            attachmentId: attachmentID
        )

        XCTAssertFalse(
            AttachmentPaths.isReadableStoragePath(
                legacyPath,
                messageId: messageID,
                attachmentId: attachmentID
            )
        )
        XCTAssertFalse(
            AttachmentPaths.isReadableStoragePath(
                currentPath,
                messageId: nil,
                attachmentId: attachmentID
            )
        )
        XCTAssertTrue(
            AttachmentPaths.isReadableStoragePath(
                currentPath,
                messageId: messageID,
                attachmentId: attachmentID
            )
        )
    }

    func testReadableStoragePathPreservesLocalComposeAttachments() {
        XCTAssertTrue(
            AttachmentPaths.isReadableStoragePath(
                "Attachments/local_example.jpg",
                messageId: nil,
                attachmentId: "local_example"
            )
        )
        XCTAssertTrue(
            AttachmentPaths.isReadableStoragePath(
                "Attachments/local_example.jpg",
                messageId: "sent-message",
                attachmentId: "local_example"
            )
        )
    }

    func testReadableStoragePathScopesSynthesizedInlineAttachmentsToMessage() {
        let attachmentID = "local_inline_reused-metadata-hash"
        let messageID = "message-one"
        let legacyPath = AttachmentPaths.originalPath(idOrUUID: attachmentID, ext: "png")
        let currentPath = AttachmentPaths.originalPath(
            messageId: messageID,
            attachmentId: attachmentID,
            ext: "png"
        )

        XCTAssertFalse(
            AttachmentPaths.isReadableStoragePath(
                legacyPath,
                messageId: messageID,
                attachmentId: attachmentID
            )
        )
        XCTAssertTrue(
            AttachmentPaths.isReadableStoragePath(
                currentPath,
                messageId: messageID,
                attachmentId: attachmentID
            )
        )
    }

    func testSynthesizedInlineCacheIdentityIsMessageScoped() {
        let attachmentId = "local_inline_reused-metadata-hash"

        XCTAssertNotEqual(
            AttachmentPaths.cacheIdentity(
                messageId: "message-one",
                attachmentId: attachmentId
            ),
            AttachmentPaths.cacheIdentity(
                messageId: "message-two",
                attachmentId: attachmentId
            )
        )
        XCTAssertEqual(
            AttachmentPaths.cacheIdentity(
                messageId: nil,
                attachmentId: attachmentId
            ),
            attachmentId
        )
    }

    func testSynthesizedInlinePayloadRecoveryRecomputesMessageProcessorIdentity() throws {
        let data = Data("authoritative embedded bytes".utf8)
        let encodedData = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let contentID = "inline-recovery@example.com"
        let partID = "1.2"
        let filename = "forwarded.txt"
        let mimeType = "text/plain"
        let expectedID = AttachmentPaths.synthesizedInlineAttachmentID(
            partId: partID,
            trimmedFilename: filename,
            mimeType: mimeType,
            contentId: contentID,
            size: data.count
        )
        let message = GmailMessage(
            id: "message-inline-recovery",
            threadId: "thread-inline-recovery",
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: MessagePart(
                partId: "",
                mimeType: "multipart/related",
                filename: nil,
                headers: nil,
                body: nil,
                parts: [
                    MessagePart(
                        partId: partID,
                        mimeType: mimeType,
                        filename: filename,
                        headers: [
                            MessageHeader(name: "Content-ID", value: "<\(contentID)>"),
                            MessageHeader(name: "Content-Disposition", value: "inline")
                        ],
                        body: MessageBody(
                            size: data.count,
                            data: encodedData,
                            attachmentId: nil
                        ),
                        parts: nil
                    )
                ]
            ),
            sizeEstimate: data.count
        )

        let recovered = AttachmentPaths.synthesizedInlinePayloads(in: message)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[expectedID]?.attachmentId, expectedID)
        XCTAssertEqual(recovered[expectedID]?.data, data)
        XCTAssertEqual(recovered[expectedID]?.contentId, contentID)
        XCTAssertNil(recovered["local_inline_wrong-message-row"])
    }

    func testFileExtension_videoMimeTypes() {
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/mp4"), "mp4")
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/quicktime"), "mov")
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/x-m4v"), "m4v")
    }

    func testFileExtension_videoFallback() {
        XCTAssertEqual(AttachmentPaths.fileExtension(for: "video/unknown"), "mp4")
    }
}
