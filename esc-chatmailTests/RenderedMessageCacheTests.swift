import UIKit
import XCTest
@testable import esc_chatmail

final class RenderedMessageCacheTests: XCTestCase {
    func testConcurrentRequestsCoalesceWork() async throws {
        let cache = RenderedMessageCache()
        let counter = Counter()

        async let first = cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-1"
        ) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "canonical text"
        }

        async let second = cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-1"
        ) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "canonical text"
        }

        let results = await (first, second)

        XCTAssertEqual(results.0, "canonical text")
        XCTAssertEqual(results.1, "canonical text")
        let producedCount = await counter.value()
        XCTAssertEqual(producedCount, 1)

        let statistics = await cache.getStatistics()
        XCTAssertEqual(statistics.duplicateWorkAvoided, 1)
    }

    func testDifferentSourceSignaturesCanCoexist() async throws {
        let cache = RenderedMessageCache()

        _ = await cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-1"
        ) {
            "old text"
        }

        _ = await cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-2"
        ) {
            "new text"
        }

        let staleArtifacts = await cache.artifacts(messageId: "message-1", sourceSignature: "source-1")
        let currentArtifacts = await cache.artifacts(messageId: "message-1", sourceSignature: "source-2")

        XCTAssertEqual(staleArtifacts?.canonicalPlainText, "old text")
        XCTAssertEqual(currentArtifacts?.canonicalPlainText, "new text")
    }

    func testBaseSourceLookupDoesNotPruneFallbackSourceArtifact() async throws {
        let cache = RenderedMessageCache()
        let variantKey = RenderedMessageVariantKey("chat-bubble-preview")
        let baseSourceSignature = "html:123|456"
        let fallbackSourceSignature = "html:123|456|fallback-body:sha256:body"

        await cache.storeChatBubbleText(
            RenderedMessageChatBubbleText(plainText: "fallback", hasRichContent: false),
            messageId: "message-1",
            sourceSignature: fallbackSourceSignature,
            variantKey: variantKey
        )

        let baseResult = await cache.cachedChatBubbleText(
            messageId: "message-1",
            sourceSignature: baseSourceSignature,
            variantKey: variantKey
        )
        let fallbackResult = await cache.cachedChatBubbleText(
            messageId: "message-1",
            sourceSignature: fallbackSourceSignature,
            variantKey: variantKey
        )

        XCTAssertNil(baseResult)
        XCTAssertEqual(fallbackResult?.plainText, "fallback")
    }

    func testInvalidationCancelsInFlightWorkAndDoesNotStoreResult() async throws {
        let cache = RenderedMessageCache()
        let gate = AsyncGate()

        async let result = cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-1"
        ) {
            await gate.markStarted()
            await gate.waitForRelease()
            return "stale text"
        }

        await gate.waitForStart()
        await cache.invalidate(messageId: "message-1")
        await gate.release()

        let produced = await result
        let artifacts = await cache.artifacts(messageId: "message-1", sourceSignature: "source-1")

        XCTAssertNil(produced)
        XCTAssertNil(artifacts)
    }

    func testClearCancelsInFlightWorkAndDoesNotStoreResult() async throws {
        let cache = RenderedMessageCache()
        let gate = AsyncGate()

        async let result = cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-1"
        ) {
            await gate.markStarted()
            await gate.waitForRelease()
            return "stale text"
        }

        await gate.waitForStart()
        await cache.clear()
        await gate.release()

        let produced = await result
        let artifacts = await cache.artifacts(messageId: "message-1", sourceSignature: "source-1")

        XCTAssertNil(produced)
        XCTAssertNil(artifacts)
    }

    func testPartialArtifactPopulationWorks() async throws {
        let cache = RenderedMessageCache()
        let analysis = MessageBubbleHTMLAnalysis.placeholder(hasHTMLSource: true)

        _ = await cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-1"
        ) {
            "plain text"
        }

        _ = await cache.htmlAnalysis(
            messageId: "message-1",
            sourceSignature: "source-1",
            variantKey: "analysis-v1"
        ) {
            analysis
        }

        let artifactsCandidate = await cache.artifacts(messageId: "message-1", sourceSignature: "source-1")
        let artifacts = try XCTUnwrap(artifactsCandidate)

        XCTAssertEqual(artifacts.canonicalPlainText, "plain text")
        XCTAssertEqual(artifacts.htmlAnalysisByVariant["analysis-v1"], analysis)
        XCTAssertTrue(artifacts.chatBubbleTextByVariant.isEmpty)
    }

    func testMemoryPressureClearsEntries() async throws {
        let cache = RenderedMessageCache()

        _ = await cache.canonicalPlainText(
            messageId: "message-1",
            sourceSignature: "source-1"
        ) {
            "plain text"
        }

        await cache.handleMemoryWarning()

        let artifacts = await cache.artifacts(messageId: "message-1", sourceSignature: "source-1")
        let statistics = await cache.getStatistics()

        XCTAssertNil(artifacts)
        XCTAssertEqual(statistics.currentEntryCount, 0)
        XCTAssertEqual(statistics.invalidations, 1)
    }

    func testPreviewAndOriginalHTMLVariantsDoNotCollide() async throws {
        let cache = RenderedMessageCache()
        let variantKey = RenderedMessageVariantKey("shared-variant")

        let preview = await cache.wrappedPreviewHTML(
            messageId: "message-1",
            sourceSignature: "source-1",
            variantKey: variantKey
        ) {
            HTMLPreviewPayload(html: "<p>Preview</p>", previewCacheKey: "preview-key")
        }

        let original = await cache.wrappedOriginalHTML(
            messageId: "message-1",
            sourceSignature: "source-1",
            variantKey: variantKey
        ) {
            "<html><body>Original</body></html>"
        }

        let artifactsCandidate = await cache.artifacts(messageId: "message-1", sourceSignature: "source-1")
        let artifacts = try XCTUnwrap(artifactsCandidate)

        XCTAssertEqual(preview?.html, "<p>Preview</p>")
        XCTAssertEqual(original, "<html><body>Original</body></html>")
        XCTAssertEqual(artifacts.wrappedPreviewHTMLByVariant[variantKey]?.html, "<p>Preview</p>")
        XCTAssertEqual(artifacts.wrappedOriginalHTMLByVariant[variantKey], "<html><body>Original</body></html>")
    }

    func testSnapshotDiskCacheWorksIndependentlyOfRenderedMetadata() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedMessageCacheSnapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let renderedCache = RenderedMessageCache()
        let snapshotCache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let image = try XCTUnwrap(Self.image())
        let snapshotKey = "snapshot-cache-key"

        let storedCandidate = await snapshotCache.store(
            image: image,
            displayHeight: 144,
            pixelScale: 2,
            for: snapshotKey
        )
        let stored = try XCTUnwrap(storedCandidate)

        await renderedCache.recordSnapshotMetadata(
            RenderedMessageSnapshotMetadata(
                snapshotCacheKey: snapshotKey,
                displayHeight: Double(stored.displayHeight),
                pixelScale: Double(stored.pixelScale),
                createdAt: stored.createdAt
            ),
            messageId: "message-1",
            sourceSignature: "source-1",
            variantKey: "snapshot"
        )

        await renderedCache.handleMemoryWarning()

        let diskEntry = await snapshotCache.load(for: snapshotKey)
        let metadata = await renderedCache.snapshotMetadata(
            messageId: "message-1",
            sourceSignature: "source-1",
            variantKey: "snapshot"
        )

        XCTAssertNotNil(diskEntry)
        XCTAssertNil(metadata)
    }

    private static func image() -> UIImage? {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

private actor Counter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor AsyncGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForStart() async {
        if started {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForRelease() async {
        if released {
            return
        }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}
