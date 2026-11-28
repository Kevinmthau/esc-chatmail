import XCTest
@testable import esc_chatmail

/// `AttachmentPaths.writeData` and the result it classifies a failed write into
/// (architecture review 2026-11, attachments-storage-disk#5).
final class AttachmentWriteResultTests: XCTestCase {
    // Revert-check: `StorageErrorClassifier.isOutOfSpace` in
    // `AttachmentWriteResult.init(classifying:)`. Answer `.failed` for every error and a full
    // disk marks the row failed again, which the next showing downloads again.
    func testClassifying_eachOutOfSpaceError_isOutOfSpace() {
        let errors: [Error] = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT)),
            CocoaError(.fileWriteOutOfSpace),
            NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteUnknown.rawValue,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
            )
        ]
        for error in errors {
            XCTAssertEqual(AttachmentWriteResult(classifying: error), .outOfSpace, "\(error)")
        }
    }

    func testClassifying_anyOtherError_isFailed() {
        let errors: [Error] = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            CocoaError(.fileWriteNoPermission),
            URLError(.cannotWriteToFile)
        ]
        for error in errors {
            XCTAssertEqual(AttachmentWriteResult(classifying: error), .failed, "\(error)")
        }
    }

    func testWriteData_ofARedownloadableFile_isSavedWholeAndLeftOutOfBackups() throws {
        AttachmentPaths.setupDirectories()
        let path = AttachmentPaths.originalPath(
            messageId: "write-result-\(UUID().uuidString)",
            attachmentId: "attachment",
            ext: "bin"
        )
        defer { AttachmentPaths.deleteFile(at: path) }
        let bytes = Data("attachment bytes".utf8)

        XCTAssertEqual(AttachmentPaths.writeData(bytes, to: path), .saved)

        XCTAssertEqual(AttachmentPaths.loadData(from: path), bytes)
        let url = try XCTUnwrap(AttachmentPaths.fullURL(for: path))
        XCTAssertTrue(BackupExclusion.isExcluded(url))
    }

    /// A real failed write: a directory, with a file in it, where the file would go.
    func testWriteData_whereADirectoryIsInTheWay_isFailed_andSaveDataAnswersFalse() throws {
        AttachmentPaths.setupDirectories()
        let path = AttachmentPaths.originalPath(
            messageId: "write-result-blocked-\(UUID().uuidString)",
            attachmentId: "attachment",
            ext: "bin"
        )
        let url = try XCTUnwrap(AttachmentPaths.fullURL(for: path))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("in the way".utf8).write(to: url.appendingPathComponent("occupant"))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(AttachmentPaths.writeData(Data("bytes".utf8), to: path), .failed)
        XCTAssertFalse(AttachmentPaths.saveData(Data("bytes".utf8), to: path))
    }
}
