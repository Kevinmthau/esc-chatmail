#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import esc_chatmail

/// A preview snapshot taken with an image missing is shown and never stored on disk
/// (architecture review 2026-11, `web-content-rendering#3`): the real renderer reports whether
/// its capture is complete, leaving out what no later render could change, the cache keeps an
/// incomplete one in memory for a bounded time only, and the card shows it without falling back
/// to a live web view. Every real render retries WebKit startup timeouts
/// (`renderRetryingWebKitStartupTimeouts`).
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

    /// Revert-check: ignoring `HTMLPreviewSnapshotImageOutcome` in the session's `isComplete`
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

    /// An image the web content refuses on purpose (a private, loopback or single-label host) will
    /// not load at any later render, so it does not make the card incomplete: counted, a router's
    /// or NAS's notification was rendered again every ten minutes for as long as it existed.
    ///
    /// Revert-check: making `HTMLPreviewSnapshotImageOutcome.isBlockedOnPurpose` return false
    /// fails this.
    func testRender_brokenImageOnALoopbackHost_isComplete() async throws {
        let result = try await render(body: #"<p>Card</p><img src="http://127.0.0.1:1/logo.png" width="120" height="80">"#)
        XCTAssertTrue(result.isComplete)
    }

    /// A broken image the reader cannot see, because an ancestor is transparent or clips it away,
    /// or that asks for nothing (lazy-loader markup with only `data-src`), does not make the card
    /// incomplete.
    ///
    /// Revert-check: dropping the ancestor walk, or the skip of an `<img>` with no `src`, from
    /// `HTMLPreviewSnapshotImageOutcomeScript` fails this (each run alone).
    func testRender_brokenImageHiddenByAnAncestor_orWithNoSource_isComplete() async throws {
        let result = try await render(body: """
        <p>Card</p>
        <div style="opacity: 0"><img src="data:image/png;base64,AAAA" width="120" height="80"></div>
        <div style="max-height: 0; overflow: hidden"><img src="data:image/png;base64,AAAA" width="120" height="80"></div>
        <img data-src="https://cdn.example.com/lazy.png" width="120" height="80">
        """)
        XCTAssertTrue(result.isComplete)
    }

    /// A `cid:` image the scheme handler could not supply now (here: no message to read, a failed
    /// read) makes the card incomplete only where the capture shows it.
    ///
    /// Revert-check: answering `.notNamed` for a failed lookup in `CIDSchemeHandler` fails the
    /// first assertion; counting every unavailable Content-ID in
    /// `HTMLPreviewSnapshotImageOutcome.isComplete` fails the second.
    func testRender_unavailableCIDImage_isIncompleteOnlyInsideTheCapture() async throws {
        let inside = try await render(body: #"<p>Card</p><img src="cid:logo@example.com" width="120" height="80">"#)
        let below = try await render(body: """
        <p>Card</p>
        <div style="height: 2000px"></div>
        <img src="cid:logo@example.com" width="120" height="80">
        """)

        XCTAssertFalse(inside.isComplete)
        XCTAssertTrue(below.isComplete)
    }

    // MARK: - Outcome

    func testImageOutcome_blockedOnPurpose_isTheDetectorsPrivateOrReservedHosts() {
        for source in ["http://192.168.0.10/", "https://printer/", "http://[::1]/"] {
            XCTAssertTrue(HTMLPreviewSnapshotImageOutcome.isBlockedOnPurpose(source), source)
        }
        for source in ["https://cdn.example.com/", "data:", "cid:", "http://", "blob:"] {
            XCTAssertFalse(HTMLPreviewSnapshotImageOutcome.isBlockedOnPurpose(source), source)
        }
    }

    /// Revert-check: replacing the `cid:` intersection in `isComplete` with
    /// `unavailableContentIDs.isEmpty`, or dropping the truncation guard, fails this.
    func testImageOutcome_isComplete_countsOnlyWhatALaterRenderCouldChange() {
        func outcome(_ incomplete: [String], cids: [String] = [], truncated: Bool = false) -> HTMLPreviewSnapshotImageOutcome {
            HTMLPreviewSnapshotImageOutcome(incompleteSources: incomplete, capturedCIDSources: cids, isTruncated: truncated)
        }

        XCTAssertFalse(outcome(["https://cdn.example.com/"]).isComplete(unavailableContentIDs: []))
        XCTAssertFalse(outcome(["data:"]).isComplete(unavailableContentIDs: []))
        XCTAssertTrue(outcome(["http://10.0.0.1/", "https://nas/"]).isComplete(unavailableContentIDs: []))
        XCTAssertFalse(outcome([], truncated: true).isComplete(unavailableContentIDs: []))
        XCTAssertFalse(
            outcome([], cids: ["cid:%3CLogo@Example.COM%3E"]).isComplete(unavailableContentIDs: ["logo@example.com"])
        )
        XCTAssertTrue(
            outcome([], cids: ["cid:banner@example.com"]).isComplete(unavailableContentIDs: ["logo@example.com"]),
            "An unavailable image outside the capture does not count"
        )
    }

    func testImageOutcome_readsTheScriptsResult_andNothingElse() {
        let read = HTMLPreviewSnapshotImageOutcome(scriptResult: [
            "incomplete": ["https://cdn.example.com/"],
            "cids": ["cid:logo@example.com"],
            "truncated": false
        ] as [String: Any])

        XCTAssertEqual(
            read,
            HTMLPreviewSnapshotImageOutcome(
                incompleteSources: ["https://cdn.example.com/"],
                capturedCIDSources: ["cid:logo@example.com"],
                isTruncated: false
            )
        )
        XCTAssertNil(HTMLPreviewSnapshotImageOutcome(scriptResult: NSNumber(value: 0)))
        XCTAssertNil(HTMLPreviewSnapshotImageOutcome(scriptResult: nil))
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

    /// The memory tier is account state: closing account work empties it.
    ///
    /// Revert-check: removing `removeAllIncomplete()` from `closeAccountWorkAndClear` fails this.
    func testCache_incompleteTier_isClearedAtTheAccountBoundary() async throws {
        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        _ = await cache.store(image: makeImage(), displayHeight: 200, pixelScale: 2, isComplete: false, for: "c")

        try await cache.closeAccountWorkAndClear()
        try await cache.reopenAccountWork()

        let clearedCount = await cache.incompleteEntryCountForTesting
        XCTAssertEqual(clearedCount, 0)
        let afterReopen = await cache.load(for: "c")
        XCTAssertNil(afterReopen)
    }

    /// The memory tier is bounded by its images' bytes and drops the least recently used card,
    /// not the one stored first: a card shown again stays.
    ///
    /// Revert-check: removing the `lastUse` refresh from `load(for:)` drops "a" instead of "b"
    /// and fails this.
    func testCache_incompleteTier_isBoundedByBytes_leastRecentlyUsedFirst() async throws {
        let imageBytes = try XCTUnwrap(makeImage().jpegData(compressionQuality: 0.82)).count
        let cache = EmailPreviewSnapshotCache(
            cacheDirectory: tempDirectory,
            maxIncompleteBytes: imageBytes * 2 + imageBytes / 2
        )
        for key in ["a", "b"] {
            _ = await cache.store(image: makeImage(), displayHeight: 200, pixelScale: 2, isComplete: false, for: key)
        }
        let shownAgain = await cache.load(for: "a")
        XCTAssertNotNil(shownAgain)

        _ = await cache.store(image: makeImage(), displayHeight: 200, pixelScale: 2, isComplete: false, for: "c")

        let boundedCount = await cache.incompleteEntryCountForTesting
        XCTAssertEqual(boundedCount, 2)
        let a = await cache.load(for: "a")
        let b = await cache.load(for: "b")
        let c = await cache.load(for: "c")
        XCTAssertNotNil(a, "The card shown again is the most recently used")
        XCTAssertNil(b, "The least recently used card is dropped")
        XCTAssertNotNil(c)
    }

    /// An image larger than the whole bound is kept alone rather than dropped on arrival.
    ///
    /// Revert-check: removing `incompleteEntries.count > 1` from `storeIncomplete`'s loop fails
    /// this.
    func testCache_incompleteTier_keepsAnImageLargerThanTheBoundAlone() async throws {
        let imageBytes = try XCTUnwrap(makeImage().jpegData(compressionQuality: 0.82)).count
        let largeBytes = try XCTUnwrap(makeImage(side: 400).jpegData(compressionQuality: 0.82)).count
        XCTAssertGreaterThan(largeBytes, imageBytes * 2, "Precondition: the large image is past the bound alone")
        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory, maxIncompleteBytes: imageBytes * 2)
        _ = await cache.store(image: makeImage(), displayHeight: 200, pixelScale: 2, isComplete: false, for: "small")

        _ = await cache.store(
            image: makeImage(side: 400),
            displayHeight: 200,
            pixelScale: 2,
            isComplete: false,
            for: "large"
        )

        let count = await cache.incompleteEntryCountForTesting
        XCTAssertEqual(count, 1)
        let large = await cache.load(for: "large")
        XCTAssertNotNil(large)
    }

    /// A stored snapshot's age is measured on the cache's one clock, as the memory tier's
    /// lifetime is.
    ///
    /// Revert-check: putting `Date()` back for `now()` in `load(for:)`'s age check fails this.
    func testCache_diskTierAge_isMeasuredOnTheInjectedClock() async throws {
        let clock = TestClock(Date())
        let cache = EmailPreviewSnapshotCache(
            cacheDirectory: tempDirectory,
            maxCacheAge: 60,
            now: { clock.now }
        )
        _ = await cache.store(image: makeImage(), displayHeight: 200, pixelScale: 2, isComplete: true, for: "aged")
        let fresh = await cache.load(for: "aged")
        XCTAssertNotNil(fresh)

        clock.now = clock.now.addingTimeInterval(61)

        let aged = await cache.load(for: "aged")
        XCTAssertNil(aged)
    }

    /// The render diagnostics name the tier a snapshot went to, so a memory-only store does not
    /// read as one on disk.
    func testStoredTier_namesWhereTheSnapshotWent() {
        XCTAssertEqual(EmailPreviewSnapshotStoredTier(stored: true, isComplete: true), .disk)
        XCTAssertEqual(EmailPreviewSnapshotStoredTier(stored: true, isComplete: false), .memory)
        XCTAssertEqual(EmailPreviewSnapshotStoredTier(stored: false, isComplete: true), .none)
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
        try await renderRetryingWebKitStartupTimeouts(
            EmailPreviewSnapshotRequest(
                html: "<html><body>\(body)</body></html>",
                cacheKey: "completeness-\(UUID().uuidString)",
                containerWidth: 280,
                isDarkMode: false,
                senderEmail: nil,
                message: nil
            )
        )
    }

    private func makeImage(side: CGFloat = 20) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side / 3))
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
