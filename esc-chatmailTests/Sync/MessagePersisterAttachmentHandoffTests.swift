import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class MessagePersisterAttachmentHandoffTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var persister: MessagePersister!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        persister = MessagePersister(photoPrefetcher: { _ in })
    }

    override func tearDown() {
        persister = nil
        testStack = nil
        super.tearDown()
    }

    // Revert-check: fails if `handoffOptimisticAttachmentStorage` reverts to
    // greedy first-match pairing — the ambiguous duplicate-metadata pair would
    // then hand off (bytes copied, state .downloaded) instead of staying queued
    // for its normal Gmail download, risking swapped bytes between same-named
    // sibling attachments. The unique-match half fails if the require-unique-
    // bijection rule over-tightens and stops copying an unambiguous pair.
    func testCrossMessageHandoffCopiesUniqueMatchAndLeavesDuplicateMetadataQueued() throws {
        let testID = UUID().uuidString
        let optimisticMessageID = "optimistic-ambiguous-attachments-\(testID)"
        let remoteMessageID = "remote-ambiguous-attachments-\(testID)"
        let localAttachmentIDs = [
            "local_ambiguous_first_\(testID)",
            "local_ambiguous_second_\(testID)"
        ]
        let remoteAttachmentIDs = [
            "remote-ambiguous-first-\(testID)",
            "remote-ambiguous-second-\(testID)"
        ]
        let uniqueLocalAttachmentID = "local_unique_\(testID)"
        let uniqueRemoteAttachmentID = "remote-unique-\(testID)"
        let localPaths = localAttachmentIDs.map {
            AttachmentPaths.originalPath(idOrUUID: $0, ext: "pdf")
        }
        let remotePaths = remoteAttachmentIDs.map {
            AttachmentPaths.originalPath(
                messageId: remoteMessageID,
                attachmentId: $0,
                ext: "pdf"
            )
        }
        let uniqueLocalPath = AttachmentPaths.originalPath(
            idOrUUID: uniqueLocalAttachmentID,
            ext: "pdf"
        )
        let uniqueRemotePath = AttachmentPaths.originalPath(
            messageId: remoteMessageID,
            attachmentId: uniqueRemoteAttachmentID,
            ext: "pdf"
        )
        defer {
            (localPaths + remotePaths + [uniqueLocalPath, uniqueRemotePath])
                .forEach(AttachmentPaths.deleteFile(at:))
        }

        AttachmentPaths.setupDirectories()
        XCTAssertTrue(
            AttachmentPaths.saveData(Data(repeating: 0x01, count: 32), to: localPaths[0])
        )
        XCTAssertTrue(
            AttachmentPaths.saveData(Data(repeating: 0x02, count: 32), to: localPaths[1])
        )
        let uniqueData = Data(repeating: 0x03, count: 16)
        XCTAssertTrue(AttachmentPaths.saveData(uniqueData, to: uniqueLocalPath))

        let context = testStack.viewContext
        let optimisticMessage = MessageBuilder()
            .withId(optimisticMessageID)
            .withAttachments()
            .build(in: context)
        let remoteMessage = MessageBuilder()
            .withId(remoteMessageID)
            .withAttachments()
            .build(in: context)

        let optimisticAttachments = zip(localAttachmentIDs, localPaths).map { id, path in
            let attachment = AttachmentBuilder()
                .withId(id)
                .withFilename("duplicate.pdf")
                .withMimeType("application/pdf")
                .withByteSize(32)
                .withLocalURL(path)
                .forMessage(optimisticMessage)
                .build(in: context)
            attachment.state = .uploaded
            return attachment
        }
        let remoteAttachments = remoteAttachmentIDs.map { id in
            AttachmentBuilder()
                .withId(id)
                .withFilename("duplicate.pdf")
                .withMimeType("application/pdf")
                .withByteSize(32)
                .queued()
                .forMessage(remoteMessage)
                .build(in: context)
        }
        let uniqueOptimisticAttachment = AttachmentBuilder()
            .withId(uniqueLocalAttachmentID)
            .withFilename("unique.pdf")
            .withMimeType("application/pdf")
            .withByteSize(16)
            .withLocalURL(uniqueLocalPath)
            .forMessage(optimisticMessage)
            .build(in: context)
        uniqueOptimisticAttachment.state = .uploaded
        let uniqueRemoteAttachment = AttachmentBuilder()
            .withId(uniqueRemoteAttachmentID)
            .withFilename("unique.pdf")
            .withMimeType("application/pdf")
            .withByteSize(16)
            .queued()
            .forMessage(remoteMessage)
            .build(in: context)

        let objectsNeedingPermanentIDs: [NSManagedObject] =
            [
                optimisticMessage,
                remoteMessage,
                uniqueOptimisticAttachment,
                uniqueRemoteAttachment
            ] + optimisticAttachments + remoteAttachments
        try context.obtainPermanentIDs(for: objectsNeedingPermanentIDs)
        let resolution = MessagePersister.RemoteCommittedSendMutationResolution(
            recordObjectIDs: [],
            supersededOptimisticMessages: [
                optimisticMessage.objectID: MessagePersister.SupersededOptimisticMessage(
                    optimisticMessageID: optimisticMessageID,
                    newlyInsertedConversation: false
                )
            ],
            anchoredListConversationObjectID: nil,
            anchoredListId: nil,
            shouldConsumeAfterPersistence: true
        )
        let attachmentInfos = remoteAttachmentIDs.map {
            AttachmentInfo(
                id: $0,
                filename: "duplicate.pdf",
                mimeType: "application/pdf",
                size: 32,
                contentId: nil
            )
        } + [
            AttachmentInfo(
                id: uniqueRemoteAttachmentID,
                filename: "unique.pdf",
                mimeType: "application/pdf",
                size: 16,
                contentId: nil
            )
        ]

        persister.handoffOptimisticAttachmentStorage(
            resolution,
            attachmentInfos: attachmentInfos,
            to: remoteMessage,
            in: context
        )

        XCTAssertTrue(remoteAttachments.allSatisfy { $0.state == .queued })
        XCTAssertTrue(remoteAttachments.allSatisfy { $0.localURL == nil })
        for remotePath in remotePaths {
            let remoteURL = try XCTUnwrap(AttachmentPaths.fullURL(for: remotePath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: remoteURL.path))
        }
        XCTAssertEqual(optimisticAttachments.map(\.localURL), localPaths.map(Optional.some))
        XCTAssertEqual(uniqueRemoteAttachment.state, .downloaded)
        XCTAssertEqual(uniqueRemoteAttachment.localURL, uniqueRemotePath)
        XCTAssertEqual(AttachmentPaths.loadData(from: uniqueRemotePath), uniqueData)
        XCTAssertNil(uniqueOptimisticAttachment.localURL)
    }
}
