import XCTest
@testable import esc_chatmail

/// The body messages.send streams (`GmailMultipartSendUpload`): the MIME byte for
/// byte as the `message/rfc822` part, the thread ID in the JSON part, a boundary the
/// MIME never contains, and old files left by a killed send removed.
final class GmailMultipartSendUploadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GmailMultipartSendUploadTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private static let mime = Data("From: me@example.com\r\nSubject: hi\r\n\r\nbody\r\n".utf8)

    func testWrite_withThreadID_isTheMultipartBodyGmailExpects() throws {
        let upload = try GmailMultipartSendUpload.write(
            mimeData: Self.mime,
            threadId: "thread-1",
            in: directory,
            makeBoundary: { "B0UNDARY" }
        )

        let body = try Data(contentsOf: upload.fileURL)
        let expected = Data(
            ("--B0UNDARY\r\n"
                + "Content-Type: application/json; charset=UTF-8\r\n\r\n"
                + #"{"threadId":"thread-1"}"#
                + "\r\n--B0UNDARY\r\n"
                + "Content-Type: message/rfc822\r\n\r\n").utf8
        ) + Self.mime + Data("\r\n--B0UNDARY--\r\n".utf8)
        XCTAssertEqual(body, expected)
        XCTAssertEqual(upload.boundary, "B0UNDARY")
        XCTAssertEqual(upload.contentType, "multipart/related; boundary=B0UNDARY")
    }

    func testWrite_withoutThreadID_sendsEmptyMetadata() throws {
        let upload = try GmailMultipartSendUpload.write(
            mimeData: Self.mime,
            threadId: nil,
            in: directory,
            makeBoundary: { "B0UNDARY" }
        )

        let body = try XCTUnwrap(String(data: try Data(contentsOf: upload.fileURL), encoding: .utf8))
        XCTAssertTrue(body.contains("charset=UTF-8\r\n\r\n{}\r\n--B0UNDARY\r\n"), body)
    }

    /// The MIME part is binary-safe: bytes that are not UTF-8 arrive unchanged.
    func testWrite_mimePart_isTheMIMEByteForByte() throws {
        var mime = Self.mime
        mime.append(contentsOf: [0x00, 0xFF, 0xFE, 0x80])
        let upload = try GmailMultipartSendUpload.write(
            mimeData: mime,
            threadId: nil,
            in: directory,
            makeBoundary: { "B0UNDARY" }
        )

        let body = try Data(contentsOf: upload.fileURL)
        let head = Data("Content-Type: message/rfc822\r\n\r\n".utf8)
        let tail = Data("\r\n--B0UNDARY--\r\n".utf8)
        let start = try XCTUnwrap(body.range(of: head)).upperBound
        let end = try XCTUnwrap(body.range(of: tail, options: .backwards)).lowerBound
        XCTAssertEqual(body.subdata(in: start..<end), mime)
    }

    /// Revert-check: the `while mimeData.range(of:)` loop in `write`: the body then
    /// uses a boundary the MIME contains, which ends the part early.
    func testWrite_boundaryFoundInTheMIME_isReplaced() throws {
        let mime = Data("Subject: x\r\n\r\n--COLLIDES in the text\r\n".utf8)
        var boundaries = ["COLLIDES", "FRESH"]

        let upload = try GmailMultipartSendUpload.write(
            mimeData: mime,
            threadId: nil,
            in: directory,
            makeBoundary: { boundaries.removeFirst() }
        )

        XCTAssertEqual(upload.boundary, "FRESH")
        XCTAssertTrue(boundaries.isEmpty)
    }

    func testWrite_twoSends_writeTwoFiles() throws {
        let first = try GmailMultipartSendUpload.write(mimeData: Self.mime, threadId: nil, in: directory)
        let second = try GmailMultipartSendUpload.write(mimeData: Self.mime, threadId: nil, in: directory)

        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertNotEqual(first.boundary, second.boundary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    func testRemove_deletesTheFileAndToleratesAMissingOne() throws {
        let upload = try GmailMultipartSendUpload.write(mimeData: Self.mime, threadId: nil, in: directory)

        upload.remove()
        upload.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.fileURL.path))
    }

    /// Revert-check: `removeStaleFiles` in `write`: the file a killed send left
    /// stays on disk for good.
    func testWrite_removesFilesOlderThanTheStaleAgeAndKeepsRecentOnes() throws {
        let now = Date()
        let old = try GmailMultipartSendUpload.write(mimeData: Self.mime, threadId: nil, in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(GmailMultipartSendUpload.staleFileAge + 60))],
            ofItemAtPath: old.fileURL.path
        )
        let recent = try GmailMultipartSendUpload.write(mimeData: Self.mime, threadId: nil, in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(GmailMultipartSendUpload.staleFileAge - 60))],
            ofItemAtPath: recent.fileURL.path
        )

        let new = try GmailMultipartSendUpload.write(mimeData: Self.mime, threadId: nil, in: directory, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.fileURL.path))
    }

    /// No file in use can be stale: the age is well past a send's longest life.
    func testStaleFileAge_isPastASendsLongestLife() {
        XCTAssertGreaterThan(GmailMultipartSendUpload.staleFileAge, 2 * NetworkConfig.sendResourceTimeout)
    }

    func testWrite_directoryCannotBeMade_throws() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))

        XCTAssertThrowsError(
            try GmailMultipartSendUpload.write(
                mimeData: Self.mime,
                threadId: nil,
                in: blocker.appendingPathComponent("uploads", isDirectory: true)
            )
        )
    }
}
