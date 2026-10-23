import XCTest
import CoreData
@testable import esc_chatmail

/// Pins `AttachmentDownloader.cleanupOrphanedFiles()`: the nightly sweep that
/// deletes files under Attachments/ and Previews/ that no Attachment row names.
///
/// The sweep walks the test host's real Application Support directories, so
/// every fixture is UUID-named and removed in teardown, and the database
/// snapshot is injected instead of read from rows.
@MainActor
final class AttachmentOrphanSweepTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var createdFiles: [URL] = []

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
    }

    override func tearDown() {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles = []
        testStack = nil
        super.tearDown()
    }

    /// Revert-check: returning an empty set instead of nil from the snapshot's
    /// `catch` in `AttachmentDownloader.performCleanupOrphanedFiles` deletes
    /// both files.
    func testCleanupOrphanedFiles_whenAttachmentPathsCannotBeRead_keepsEveryFile() async throws {
        let original = try makeFile(
            at: AttachmentPaths.originalPath(idOrUUID: "sent-original-\(UUID().uuidString)", ext: "jpg"),
            age: 2 * 24 * 60 * 60
        )
        let preview = try makeFile(
            at: AttachmentPaths.previewPath(idOrUUID: "sent-preview-\(UUID().uuidString)"),
            age: 2 * 24 * 60 * 60
        )
        let downloader = makeDownloader { _ in
            throw NSError(domain: NSSQLiteErrorDomain, code: 10)
        }

        await downloader.cleanupOrphanedFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: original.path),
            "A failed read is not 'no attachments'; the user's sent originals cannot be re-downloaded"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
    }

    /// Revert-check: dropping the `isOldEnoughToSweep` condition in
    /// `AttachmentDownloader.performCleanupOrphanedFiles` deletes the recent
    /// file.
    func testCleanupOrphanedFiles_keepsReferencedAndRecentFiles_removesOldOrphans() async throws {
        let referencedPath = AttachmentPaths.originalPath(idOrUUID: "referenced-\(UUID().uuidString)", ext: "pdf")
        let referenced = try makeFile(at: referencedPath, age: 2 * 24 * 60 * 60)
        let recent = try makeFile(
            at: AttachmentPaths.originalPath(idOrUUID: "row-not-saved-yet-\(UUID().uuidString)", ext: "jpg"),
            age: 60
        )
        let oldOrphan = try makeFile(
            at: AttachmentPaths.previewPath(idOrUUID: "old-orphan-\(UUID().uuidString)"),
            age: 2 * 60 * 60
        )
        let downloader = makeDownloader { _ in
            [["localURL": referencedPath] as NSDictionary]
        }

        await downloader.cleanupOrphanedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recent.path),
            "A file written just before its row is saved must survive a snapshot that cannot see the row"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOrphan.path))
    }

    func testIsOldEnoughToSweep_missingFile_isKept() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")

        XCTAssertFalse(AttachmentDownloader.isOldEnoughToSweep(missing, cutoff: Date()))
    }

    private func makeDownloader(
        fetchAttachmentFileReferences: @escaping @Sendable (NSManagedObjectContext) throws -> [NSDictionary]
    ) -> AttachmentDownloader {
        AttachmentDownloader(
            apiClient: MockGmailAPIClient(),
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            fetchAttachmentFileReferences: fetchAttachmentFileReferences
        )
    }

    /// Writes a file and backdates both its creation and modification dates.
    private func makeFile(at relativePath: String, age: TimeInterval) throws -> URL {
        let url = try XCTUnwrap(AttachmentPaths.fullURL(for: relativePath))
        XCTAssertTrue(AttachmentPaths.saveData(Data("bytes".utf8), to: relativePath))
        createdFiles.append(url)
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
        return url
    }
}
