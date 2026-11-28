#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import esc_chatmail

/// A preview snapshot taken with an image missing is shown and never stored on disk
/// (architecture review 2026-11, `web-content-rendering#3`): the real renderer reports whether
/// its capture is complete, the cache keeps an incomplete one in memory for a bounded time only,
/// and the card shows it without falling back to a live web view.
@MainActor
final class EmailPreviewSnapshotCompletenessTests: XCTestCase {
    private var tempDirectory: URL!
    private let transparentGIF = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmailPreviewSnapshotCompletenessTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Real renderer

    /// Revert-check: making `countIncompleteImages` return 0 (or dropping it from `isComplete`)
    /// fails this.
    func testRender_brokenImageInTheCapture_isIncomplete() async throws {
        let result = try await render(body: #"<p>Card</p><img src="data:image/png;base64,AAAA" width="120" height="80">"#)
        XCTAssertFalse(result.isComplete)
    }

    func testRender_loadedImageOrNoImage_isComplete() async throws {
        let withImage = try await render(body: #"<p>Card</p><img src="\#(transparentGIF)" width="120" height="80">"#)
        let withoutImage = try await render(body: "<p>Card without images</p>")

        XCTAssertTrue(withImage.isComplete)
        XCTAssertTrue(withoutImage.isComplete)
    }

    /// A broken tracking pixel or spacer, and a broken image below what the card captures, do not
    /// make a card incomplete: a dead tracker host would otherwise keep it from ever being stored.
    ///
    /// Revert-check: dropping the 2×2 size skip, or the capture-height skip, from
    /// `HTMLPreviewSnapshotImageOutcomeScript` fails this (each run alone).
    func testRender_brokenPixelOrImageOutsideTheCapture_isComplete() async throws {
        let result = try await render(body: """
        <p>Card</p>
        <img src="data:image/png;base64,AAAA" width="1" height="1">
        <div style="height: 2000px"></div>
        <img src="data:image/png;base64,AAAA" width="120" height="80">
        """)
        XCTAssertTrue(result.isComplete)
    }

    // MARK: - Cache

    /// Revert-check: removing the `guard isComplete` branch from `EmailPreviewSnapshotCache.store`
    /// writes the incomplete snapshot to disk and fails the fresh cache's load.
    func testCache_incompleteSnapshot_isServedFromMemoryOnly_untilItsLifetimeEnds() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let cache = EmailPreviewSnapshotCache(
            cacheDirectory: tempDirectory,
            incompleteEntryLifetime: 600,
            now: { clock.now }
        )

        let stored = await cache.store(
            image: makeImage(),
            displayHeight: 210,
            pixelScale: 2,
            isComplete: false,
            for: "incomplete-key"
        )

        XCTAssertNotNil(stored)
        let loadedNow = await cache.load(for: "incomplete-key")
        XCTAssertEqual(loadedNow?.displayHeight, 210)
        let freshCache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let loadedAcrossLaunches = await freshCache.load(for: "incomplete-key")
        XCTAssertNil(loadedAcrossLaunches, "Nothing incomplete is on disk")

        clock.now = clock.now.addingTimeInterval(601)
        let loadedLater = await cache.load(for: "incomplete-key")
        XCTAssertNil(loadedLater, "After its lifetime the card renders again")
    }

    /// A complete render replaces an incomplete one and goes to disk.
    func testCache_completeSnapshot_replacesTheIncompleteOne_onDisk() async throws {
        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        _ = await cache.store(image: makeImage(), displayHeight: 200, pixelScale: 2, isComplete: false, for: "key")

        _ = await cache.store(image: makeImage(), displayHeight: 240, pixelScale: 2, isComplete: true, for: "key")

        let incompleteCount = await cache.incompleteEntryCountForTesting
        XCTAssertEqual(incompleteCount, 0)
        let fresh = await EmailPreviewSnapshotCache(cacheDirectory: tempDirectory).load(for: "key")
        XCTAssertEqual(fresh?.displayHeight, 240)
    }

    /// The memory tier is account state: closing account work empties it, and it holds a bounded
    /// number of snapshots, the oldest dropped first.
    ///
    /// Revert-check: removing `incompleteEntries.removeAll()` from `closeAccountWorkAndClear`
    /// fails this.
    func testCache_incompleteTier_isClearedAtTheAccountBoundary_andBounded() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let cache = EmailPreviewSnapshotCache(
            cacheDirectory: tempDirectory,
            maxIncompleteEntries: 2,
            now: { clock.now }
        )
        for key in ["a", "b", "c"] {
            _ = await cache.store(image: makeImage(), displayHeight: 200, pixelScale: 2, isComplete: false, for: key)
            clock.now = clock.now.addingTimeInterval(1)
        }
        let boundedCount = await cache.incompleteEntryCountForTesting
        XCTAssertEqual(boundedCount, 2)
        let oldest = await cache.load(for: "a")
        XCTAssertNil(oldest)

        try await cache.closeAccountWorkAndClear()
        try await cache.reopenAccountWork()

        let clearedCount = await cache.incompleteEntryCountForTesting
        XCTAssertEqual(clearedCount, 0)
        let afterReopen = await cache.load(for: "c")
        XCTAssertNil(afterReopen)
    }

    // MARK: - View model

    /// An incomplete render is shown, as any render is, and is not a failure, which would swap the
    /// card for a live web view; it is only not stored on disk.
    ///
    /// Revert-check: passing `isComplete: true` from `EmailPreviewSnapshotViewModel.loadSnapshot`
    /// to the cache fails the fresh cache's load.
    func testViewModel_incompleteRender_isShown_andNotStoredOnDisk() async {
        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let renderer = IncompleteResultRenderer(image: makeImage())
        let viewModel = EmailPreviewSnapshotViewModel(cache: cache, renderer: renderer)
        let html = "<html><body>Incomplete preview</body></html>"
        let cacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "incomplete-message|source",
            renderedHTML: html,
            containerWidth: 300,
            isDarkMode: false
        )

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "incomplete-message|source",
            isDarkMode: false,
            senderEmail: "sender@example.com",
            message: nil,
            messageId: "incomplete-message",
            containerWidth: 300
        )

        XCTAssertNotNil(viewModel.snapshotImage)
        XCTAssertFalse(viewModel.didFail)
        XCTAssertEqual(viewModel.displayHeight, 230)
        XCTAssertEqual(viewModel.completedCacheKey, cacheKey)
        let onDisk = await EmailPreviewSnapshotCache(cacheDirectory: tempDirectory).load(for: cacheKey)
        XCTAssertNil(onDisk)
    }

    // MARK: - Fixtures

    private func render(body: String) async throws -> EmailPreviewSnapshotResult {
        let session = try EmailPreviewSnapshotRenderSession(
            request: EmailPreviewSnapshotRequest(
                html: "<html><body>\(body)</body></html>",
                cacheKey: "completeness-\(UUID().uuidString)",
                containerWidth: 280,
                isDarkMode: false,
                senderEmail: nil,
                message: nil
            )
        )
        return try await session.render()
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }
}

/// A clock the test moves. `@unchecked Sendable`: only the test's main-actor body sets and reads
/// it, between the cache's awaits.
private final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
private final class IncompleteResultRenderer: EmailPreviewSnapshotRendering {
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
    }

    func render(request: EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult {
        EmailPreviewSnapshotResult(
            image: image,
            displayHeight: 230,
            pixelScale: 2,
            cacheKey: request.cacheKey,
            isComplete: false
        )
    }
}
#endif
