import XCTest

/// Received attachments download only when something asks for them, never after a sync
/// (`AttachmentDownloader`; architecture review 2026-11, attachments-storage-disk#3).
///
/// HONEST SCOPE: this reads source text, as `AttachmentExportSourceTests` does. It pins that
/// no sync file reaches the downloader, which is how the old post-sync sweep was started; it
/// cannot see a sweep started some other way.
final class AttachmentOnDemandDownloadSourceTests: XCTestCase {
    /// Revert-check: calling `AttachmentDownloader.shared` from `SyncEngine.swift` again
    /// makes this fail.
    func testNoSyncFileReachesTheAttachmentDownloader() throws {
        let syncDirectory = repoFile("esc-chatmail/Services/Sync")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: syncDirectory, includingPropertiesForKeys: nil)
        )
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                source.contains("AttachmentDownloader") || source.contains("attachmentDownloader"),
                "\(url.lastPathComponent) reaches the attachment downloader"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10, "Positive control: the sync sources were read")
    }

    func testDownloaderHasNoSweepOfQueuedRows() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Services/Attachments/AttachmentDownloader.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("func schedulePendingAttachmentDownloads"))
        XCTAssertFalse(source.contains("func enqueueAllPendingAttachments"))
        XCTAssertTrue(source.contains("func downloadAttachmentIfNeeded(for attachment: Attachment) async"))
    }

    private func repoFile(_ relativePath: String) -> URL {
        // This file is esc-chatmailTests/Attachments/, so the repo root is three directories up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
