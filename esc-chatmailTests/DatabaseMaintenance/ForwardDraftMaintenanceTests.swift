import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ForwardDraftMaintenanceTests: XCTestCase {
    func testDatabaseSweepKeepsLiveForwardCopiesAndDeletesAbandonedRows() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.makeMainQueueViewContext()
        let leases = ComposeAttachmentLeaseRegistry()
        let manager = ComposeAttachmentManager(viewContext: context, leaseRegistry: leases)
        let originalPath = makeSourceFile()
        defer {
            manager.clear()
            AttachmentPaths.deleteFile(at: originalPath)
        }
        let copied = try XCTUnwrap(manager.copyAttachmentForForward(snapshot(path: originalPath)))
        manager.addAttachment(copied)
        let abandoned = AttachmentBuilder().withId("local_abandoned-\(UUID().uuidString)").build(in: context)
        try context.save()
        let copiedID = copied.objectID
        let abandonedID = abandoned.objectID

        let cleanupContext = stack.newBackgroundContext()
        let deletedIDs = try cleanupContext.performAndWait {
            try DatabaseMaintenanceService.deleteOrphanedAttachments(in: cleanupContext, leases: leases)
        }

        XCTAssertTrue(deletedIDs.contains(abandonedID))
        XCTAssertFalse(deletedIDs.contains(copiedID))
        try cleanupContext.performAndWait {
            XCTAssertNotNil(try cleanupContext.existingObject(with: copiedID) as? Attachment)
        }
        XCTAssertEqual(AttachmentPaths.loadData(from: copied.localURL), Data("source-pdf".utf8))
    }

    func testFilesystemSweepKeepsUnsavedForwardOriginalAndPreviewCopies() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let leases = ComposeAttachmentLeaseRegistry()
        let manager = ComposeAttachmentManager(viewContext: context, leaseRegistry: leases)
        let originalPath = makeSourceFile()
        let sourcePreview = AttachmentPaths.previewPath(idOrUUID: "forward-source-\(UUID().uuidString)")
        XCTAssertTrue(AttachmentPaths.saveData(Data("preview".utf8), to: sourcePreview))
        defer {
            manager.clear()
            AttachmentPaths.deleteFile(at: originalPath)
            AttachmentPaths.deleteFile(at: sourcePreview)
        }
        let copied = try XCTUnwrap(manager.copyAttachmentForForward(snapshot(path: originalPath, preview: sourcePreview)))
        manager.addAttachment(copied)
        XCTAssertTrue(copied.objectID.isTemporaryID)

        for path in [try XCTUnwrap(copied.localURL), try XCTUnwrap(copied.previewURL)] {
            let url = try XCTUnwrap(AttachmentPaths.fullURL(for: path))
            AttachmentDownloader.removeOrphanedFile(at: url, relativePath: path, leases: leases)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let abandonedPath = makeSourceFile()
        let abandonedURL = try XCTUnwrap(AttachmentPaths.fullURL(for: abandonedPath))
        AttachmentDownloader.removeOrphanedFile(at: abandonedURL, relativePath: abandonedPath, leases: leases)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedURL.path))
    }

    func testReleasedLeaseAllowsCleanupButSentMessageOwnershipKeepsAttachment() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.makeMainQueueViewContext()
        let leases = ComposeAttachmentLeaseRegistry()
        let manager = ComposeAttachmentManager(viewContext: context, leaseRegistry: leases)
        let originalPath = makeSourceFile()
        let copied = try XCTUnwrap(manager.copyAttachmentForForward(snapshot(path: originalPath)))
        manager.addAttachment(copied)
        let copiedPath = try XCTUnwrap(copied.localURL)
        defer {
            AttachmentPaths.deleteFile(at: originalPath)
            AttachmentPaths.deleteFile(at: copiedPath)
        }
        copied.message = MessageBuilder().withId("sent-forward-\(UUID().uuidString)").build(in: context)
        try context.save()
        let copiedID = copied.objectID
        manager.relinquishAttachmentsAfterSend()
        manager.clear()

        let cleanupContext = stack.newBackgroundContext()
        let deleted = try cleanupContext.performAndWait {
            try DatabaseMaintenanceService.deleteOrphanedAttachments(in: cleanupContext, leases: leases)
        }
        XCTAssertFalse(deleted.contains(copiedID))
        XCTAssertNotNil(AttachmentPaths.loadData(from: copiedPath))
        leases.withProtectedResources { XCTAssertTrue($0.attachmentIDs.isEmpty) }
    }

    func testFilesystemSnapshotBeforeCopyCannotDeleteFileHandedOffDuringSweep() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let leases = ComposeAttachmentLeaseRegistry()
        let manager = ComposeAttachmentManager(viewContext: context, leaseRegistry: leases)
        let originalPath = makeSourceFile()
        defer { AttachmentPaths.deleteFile(at: originalPath) }
        // The sweep's persisted valid-file snapshot predates this draft.
        let sweep = leases.beginFileCleanup()
        let copied = try XCTUnwrap(manager.copyAttachmentForForward(snapshot(path: originalPath)))
        manager.addAttachment(copied)
        let copiedPath = try XCTUnwrap(copied.localURL)
        defer { AttachmentPaths.deleteFile(at: copiedPath) }
        let copiedURL = try XCTUnwrap(AttachmentPaths.fullURL(for: copiedPath))
        copied.message = MessageBuilder().withId("handoff-during-cleanup-\(UUID().uuidString)").build(in: context)
        try context.save()
        manager.relinquishAttachmentsAfterSend()

        AttachmentDownloader.removeOrphanedFile(at: copiedURL, relativePath: copiedPath, leases: leases)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        leases.endFileCleanup(sweep)
        leases.withProtectedResources {
            XCTAssertTrue($0.filePaths.isEmpty, "Sweep protection is bounded by its completion")
        }
    }

    private func makeSourceFile() -> String {
        AttachmentPaths.setupDirectories()
        let path = AttachmentPaths.originalPath(idOrUUID: "local_source-\(UUID().uuidString)", ext: "pdf")
        XCTAssertTrue(AttachmentPaths.saveData(Data("source-pdf".utf8), to: path))
        return path
    }

    // Revert-check: `AttachmentPaths.applyBackupPolicy(toFileAt:)` after the copy in
    // `ComposeAttachmentManager.copyAttachmentForForward`. Without it the copy keeps the
    // mark `copyItem` brought from the downloaded file, and a restored device has the
    // forward's draft without its attachment.
    func testForwardCopyOfADownloadedAttachment_isBackedUp_thoughItsSourceIsNot() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let manager = ComposeAttachmentManager(viewContext: context, leaseRegistry: ComposeAttachmentLeaseRegistry())
        AttachmentPaths.setupDirectories()
        let downloadedPath = AttachmentPaths.originalPath(
            messageId: "forward-source-\(UUID().uuidString)",
            attachmentId: "att-1",
            ext: "pdf"
        )
        XCTAssertTrue(AttachmentPaths.saveData(Data("source-pdf".utf8), to: downloadedPath))
        defer {
            manager.clear()
            AttachmentPaths.deleteFile(at: downloadedPath)
        }
        let downloadedURL = try XCTUnwrap(AttachmentPaths.fullURL(for: downloadedPath))
        XCTAssertTrue(BackupExclusion.isExcluded(downloadedURL), "A downloaded attachment is left out of backups")

        let copied = try XCTUnwrap(manager.copyAttachmentForForward(snapshot(path: downloadedPath)))

        let copiedURL = try XCTUnwrap(AttachmentPaths.fullURL(for: copied.localURL))
        XCTAssertEqual(try Data(contentsOf: copiedURL), Data("source-pdf".utf8))
        XCTAssertFalse(
            BackupExclusion.isExcluded(copiedURL),
            "The forward's copy cannot be downloaded again, so it must stay in backups"
        )
    }

    private func snapshot(path: String, preview: String? = nil) -> ForwardAttachmentSnapshot {
        .init(filename: "report.pdf", mimeType: "application/pdf", byteSize: 10,
              localURL: path, previewURL: preview, width: 0, height: 0, pageCount: 1)
    }
}
