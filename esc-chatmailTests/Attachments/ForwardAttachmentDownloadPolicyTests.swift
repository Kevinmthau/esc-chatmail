import CoreData
import XCTest
@testable import esc_chatmail

/// Which attachments a forward downloads before it copies them (`ForwardAttachmentDownloadPolicy`):
/// what has no file of its message's yet and can be downloaded, never what the user attached.
///
/// The context is main-queue (`makeMainQueueViewContext`), and every test here is synchronous,
/// so XCTest runs it on the main thread, as `AttachmentDownloaderTests` explains.
final class ForwardAttachmentDownloadPolicyTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = MainActor.assumeIsolated { testStack.makeMainQueueViewContext() }
        AttachmentPaths.setupDirectories()
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    private func makeMessage(_ id: String) -> Message {
        MessageBuilder().withId(id).withAttachments().build(in: context)
    }

    func testReceivedAttachment_neverShown_needsDownload() {
        let message = makeMessage("policy-queued")
        let attachment = AttachmentBuilder().withId("att-queued").queued().forMessage(message).build(in: context)

        XCTAssertTrue(ForwardAttachmentDownloadPolicy.needsDownload(attachment))
    }

    func testReceivedAttachment_whoseDownloadFailed_isAskedForAgain() {
        let message = makeMessage("policy-failed")
        let attachment = AttachmentBuilder().withId("att-failed").failed().forMessage(message).build(in: context)

        XCTAssertTrue(ForwardAttachmentDownloadPolicy.needsDownload(attachment))
    }

    func testReceivedAttachment_withItsFile_needsNothing() {
        let message = makeMessage("policy-downloaded")
        let path = AttachmentPaths.originalPath(messageId: message.id, attachmentId: "att-downloaded", ext: "txt")
        XCTAssertTrue(AttachmentPaths.saveData(Data("bytes".utf8), to: path))
        defer { AttachmentPaths.deleteFile(at: path) }
        let attachment = AttachmentBuilder()
            .withId("att-downloaded")
            .withLocalURL(path)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        XCTAssertFalse(ForwardAttachmentDownloadPolicy.needsDownload(attachment))
    }

    /// Revert-check: dropping the `needsRedownload` case makes this fail: a row marked
    /// downloaded whose file is gone is forwarded without it.
    func testReceivedAttachment_markedDownloadedWithItsFileGone_needsDownload() {
        let message = makeMessage("policy-file-gone")
        let path = AttachmentPaths.originalPath(messageId: message.id, attachmentId: "att-file-gone", ext: "txt")
        let attachment = AttachmentBuilder()
            .withId("att-file-gone")
            .withLocalURL(path)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        XCTAssertTrue(ForwardAttachmentDownloadPolicy.needsDownload(attachment))
    }

    /// What the user attached exists only on this device: there is nothing to download, and
    /// the downloader would mark a queued one downloaded under a send that is still running.
    ///
    /// Revert-check: dropping the `local_` guard makes this fail.
    func testUsersOwnAttachment_isNeverDownloaded() {
        let message = makeMessage("policy-local")
        let attachment = AttachmentBuilder()
            .withId("local_\(UUID().uuidString)")
            .queued()
            .forMessage(message)
            .build(in: context)

        XCTAssertFalse(ForwardAttachmentDownloadPolicy.needsDownload(attachment))
    }

    /// A synthesized inline body part is recovered from its message, so it is asked for.
    func testSynthesizedInlinePart_isDownloadedFromItsMessage() {
        let message = makeMessage("policy-local-inline")
        let attachment = AttachmentBuilder()
            .withId("local_inline_abc")
            .queued()
            .forMessage(message)
            .build(in: context)

        XCTAssertTrue(ForwardAttachmentDownloadPolicy.needsDownload(attachment))
    }

    func testAttachmentBeingUploaded_isLeftAlone() {
        let message = makeMessage("policy-uploading")
        let attachment = AttachmentBuilder()
            .withId("att-uploading")
            .downloading() // the builder's name for `.uploading`
            .forMessage(message)
            .build(in: context)

        XCTAssertFalse(ForwardAttachmentDownloadPolicy.needsDownload(attachment))
    }
}
