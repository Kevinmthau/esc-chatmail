import XCTest
@testable import esc_chatmail

final class StorageMaintenanceTests: XCTestCase {
    func testIncrementalCleanupSchedule_respectsCadence() {
        let suiteName = "StorageMaintenanceTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)

        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            DataCleanupService.IncrementalCleanupSchedule.isDue(
                now: start,
                defaults: defaults
            )
        )

        DataCleanupService.IncrementalCleanupSchedule.markRun(
            now: start,
            defaults: defaults
        )

        XCTAssertFalse(
            DataCleanupService.IncrementalCleanupSchedule.isDue(
                now: start.addingTimeInterval(
                    DataCleanupService.IncrementalCleanupSchedule.interval - 1
                ),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            DataCleanupService.IncrementalCleanupSchedule.isDue(
                now: start.addingTimeInterval(
                    DataCleanupService.IncrementalCleanupSchedule.interval
                ),
                defaults: defaults
            )
        )

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testHTMLContentHandler_deleteHTML_removesLegacyBodyStorageFile() throws {
        let messageId = "storage-delete-\(UUID().uuidString)"
        let handler = HTMLContentHandler()
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).html")

        try "<p>legacy</p>".write(to: legacyURL, atomically: true, encoding: .utf8)
        _ = handler.saveHTML("<p>current</p>", for: messageId)

        handler.deleteHTML(for: messageId, bodyStorageURI: legacyURL.absoluteString)

        XCTAssertFalse(handler.htmlFileExists(for: messageId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testHTMLContentHandler_instancesShareCacheStateAcrossWritesAndDeletes() {
        let messageId = "storage-shared-cache-\(UUID().uuidString)"
        let writer = HTMLContentHandler()
        let reader = HTMLContentHandler()

        defer { writer.deleteHTML(for: messageId) }

        XCTAssertEqual(reader.htmlFileSignature(for: messageId), "missing")

        _ = writer.saveHTML("<p>first</p>", for: messageId)

        XCTAssertEqual(reader.loadHTML(for: messageId), "<p>first</p>")
        XCTAssertNotEqual(reader.htmlFileSignature(for: messageId), "missing")

        _ = writer.saveHTML("<p>second</p>", for: messageId)

        XCTAssertEqual(reader.loadHTML(for: messageId), "<p>second</p>")

        writer.deleteHTML(for: messageId)

        XCTAssertNil(reader.loadHTML(for: messageId))
        XCTAssertEqual(reader.htmlFileSignature(for: messageId), "missing")
    }

    func testHTMLContentHandler_cleanupOrphanedFiles_preservesValidMessageFiles() {
        let handler = HTMLContentHandler()
        let keepMessageId = "storage-keep-\(UUID().uuidString)"
        let removeMessageId = "storage-remove-\(UUID().uuidString)"

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let messagesDirectory = documentsURL.appendingPathComponent("Messages")
        let existingMessageIds = Set(
            (try? FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: nil))?
                .map { $0.deletingPathExtension().lastPathComponent } ?? []
        )

        _ = handler.saveHTML("<p>keep</p>", for: keepMessageId)
        _ = handler.saveHTML("<p>remove</p>", for: removeMessageId)

        var validMessageIds = existingMessageIds
        validMessageIds.insert(keepMessageId)

        handler.cleanupOrphanedFiles(validMessageIds: validMessageIds)

        XCTAssertTrue(handler.htmlFileExists(for: keepMessageId))
        XCTAssertFalse(handler.htmlFileExists(for: removeMessageId))

        handler.deleteHTML(for: keepMessageId)
    }
}
