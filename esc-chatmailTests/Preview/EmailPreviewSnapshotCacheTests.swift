import XCTest
import UIKit
@testable import esc_chatmail

final class EmailPreviewSnapshotCacheTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmailPreviewSnapshotCacheTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func testSnapshotAppearanceUsesExplicitRequestColorSchemeAndPreviewTheme() {
        XCTAssertEqual(EmailPreviewSnapshotAppearance.userInterfaceStyle(isDarkMode: false), .light)
        XCTAssertEqual(EmailPreviewSnapshotAppearance.userInterfaceStyle(isDarkMode: true), .dark)
        XCTAssertEqual(
            EmailPreviewSnapshotAppearance.theme(isDarkMode: false),
            HTMLDisplayWrapper.theme(isDarkMode: false, displayPurpose: .preview)
        )
        XCTAssertEqual(
            EmailPreviewSnapshotAppearance.theme(isDarkMode: true),
            HTMLDisplayWrapper.theme(isDarkMode: true, displayPurpose: .preview)
        )
        XCTAssertNotEqual(
            EmailPreviewSnapshotAppearance.theme(isDarkMode: true),
            HTMLDisplayWrapper.theme(isDarkMode: true, displayPurpose: .original)
        )
    }

    func testCacheKeyChangesWithPreviewSignatureWidthDarkModeContentAndRendererVersion() {
        let base = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "message|source",
            renderedHTML: "<html><body>Preview</body></html>",
            containerWidth: 280,
            isDarkMode: false
        )
        let wider = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "message|source",
            renderedHTML: "<html><body>Preview</body></html>",
            containerWidth: 320,
            isDarkMode: false
        )
        let dark = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "message|source",
            renderedHTML: "<html><body>Preview</body></html>",
            containerWidth: 280,
            isDarkMode: true
        )
        let differentContent = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "message|source",
            renderedHTML: "<html><body>Updated preview</body></html>",
            containerWidth: 280,
            isDarkMode: false
        )
        let differentPreviewSignature = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "message|different-source",
            renderedHTML: "<html><body>Preview</body></html>",
            containerWidth: 280,
            isDarkMode: false
        )

        XCTAssertNotEqual(base, wider)
        XCTAssertNotEqual(base, dark)
        XCTAssertNotEqual(base, differentContent)
        XCTAssertNotEqual(base, differentPreviewSignature)
        XCTAssertTrue(base.contains("renderer:\(EmailPreviewSnapshotCacheKey.rendererVersion)"))
    }

    func testCacheKeyChangesWithRenderedHTML() {
        let pendingRemoteImageHTML = """
        <html><body><img src="https://cdn.example.com/image.webp"></body></html>
        """
        let warmedRemoteImageHTML = """
        <html><body><img src="cid:warmed-image@example.com"></body></html>
        """

        let pending = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "message|source",
            renderedHTML: pendingRemoteImageHTML,
            containerWidth: 280,
            isDarkMode: false
        )
        let warmed = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "message|source",
            renderedHTML: warmedRemoteImageHTML,
            containerWidth: 280,
            isDarkMode: false
        )

        XCTAssertNotEqual(pending, warmed)
    }

    func testStoreAndLoadSnapshotPersistsImageDataAndMetadata() async {
        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let image = makeImage(color: .systemBlue)

        let stored = await cache.store(
            image: image,
            displayHeight: 188,
            pixelScale: 2,
            for: "snapshot-key"
        )
        let loaded = await cache.load(for: "snapshot-key")

        XCTAssertNotNil(stored)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.displayHeight, 188)
        XCTAssertEqual(loaded?.pixelScale, 2)
        XCTAssertNotNil(loaded.flatMap { UIImage(data: $0.imageData) })
    }

    func testExpiredSnapshotIsNotLoaded() async {
        let cache = EmailPreviewSnapshotCache(
            cacheDirectory: tempDirectory,
            maxCacheAge: -1
        )

        _ = await cache.store(
            image: makeImage(color: .systemRed),
            displayHeight: 188,
            pixelScale: 2,
            for: "expired-key"
        )

        let loaded = await cache.load(for: "expired-key")

        XCTAssertNil(loaded)
    }

    @MainActor
    func testViewModelLoadsCachedSnapshotWithoutRendering() async {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let html = "<html><body>Cached preview</body></html>"
        let cacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "cached-message|source",
            renderedHTML: html,
            containerWidth: 280,
            isDarkMode: false
        )
        _ = await cache.store(
            image: makeImage(color: .systemGreen),
            displayHeight: 188,
            pixelScale: 2,
            for: cacheKey
        )
        let renderer = StubSnapshotRenderer { _ in
            throw StubSnapshotRenderer.Error.unexpectedRender
        }
        let viewModel = EmailPreviewSnapshotViewModel(cache: cache, renderer: renderer)

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "cached-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "cached-message",
            containerWidth: 280
        )

        XCTAssertNotNil(viewModel.snapshotImage)
        XCTAssertEqual(viewModel.displayHeight, 188)
        XCTAssertEqual(viewModel.completedCacheKey, cacheKey)
        XCTAssertFalse(viewModel.didFail)
        XCTAssertTrue(renderer.requests.isEmpty)
        let counts = EmailPreviewSnapshotDiagnostics.countsForTesting()
        XCTAssertEqual(counts.cacheHits, 1)
        XCTAssertEqual(counts.miniEmailWebViewFallbacks, 0)
    }

    @MainActor
    func testViewModelRenderSuccessStoresCacheResult() async {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let html = "<html><body>Rendered preview</body></html>"
        let renderer = StubSnapshotRenderer { request in
            EmailPreviewSnapshotResult(
                image: self.makeImage(color: .systemPurple),
                displayHeight: 212,
                pixelScale: 2,
                cacheKey: request.cacheKey
            )
        }
        let viewModel = EmailPreviewSnapshotViewModel(cache: cache, renderer: renderer)
        let expectedCacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "rendered-message|source",
            renderedHTML: html,
            containerWidth: 300,
            isDarkMode: true
        )

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "rendered-message|source",
            isDarkMode: true,
            senderEmail: "sender@example.com",
            message: nil,
            messageId: "rendered-message",
            containerWidth: 300
        )

        let cached = await cache.load(for: expectedCacheKey)
        XCTAssertNotNil(viewModel.snapshotImage)
        XCTAssertNotNil(cached)
        XCTAssertEqual(viewModel.displayHeight, 212)
        XCTAssertEqual(viewModel.completedCacheKey, expectedCacheKey)
        XCTAssertFalse(viewModel.didFail)
        XCTAssertEqual(renderer.requests.map(\.cacheKey), [expectedCacheKey])
        XCTAssertEqual(renderer.requests.map(\.isDarkMode), [true])
        let counts = EmailPreviewSnapshotDiagnostics.countsForTesting()
        XCTAssertEqual(counts.cacheMisses, 1)
        XCTAssertEqual(counts.renderSuccesses, 1)
        XCTAssertEqual(counts.miniEmailWebViewFallbacks, 0)
    }

    @MainActor
    func testViewModelRenderFailureFallsBackToMiniEmailWebViewState() async {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let html = "<html><body>Broken preview</body></html>"
        let renderer = StubSnapshotRenderer { _ in
            throw EmailPreviewSnapshotRenderError.timeout
        }
        let viewModel = EmailPreviewSnapshotViewModel(cache: cache, renderer: renderer)

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "failed-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "failed-message",
            containerWidth: 280
        )

        XCTAssertNil(viewModel.snapshotImage)
        XCTAssertTrue(viewModel.didFail)
        XCTAssertNil(viewModel.completedCacheKey)
        let counts = EmailPreviewSnapshotDiagnostics.countsForTesting()
        XCTAssertEqual(counts.renderFailures, 1)
        XCTAssertEqual(counts.timeouts, 1)
        XCTAssertEqual(counts.miniEmailWebViewFallbacks, 1)
    }

    @MainActor
    func testViewModelCanLoadSameCacheKeyFromCacheAfterRenderFailure() async {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let html = "<html><body>Eventually cached preview</body></html>"
        let renderer = StubSnapshotRenderer { _ in
            throw EmailPreviewSnapshotRenderError.timeout
        }
        let viewModel = EmailPreviewSnapshotViewModel(
            cache: cache,
            renderer: renderer,
            retryBackoff: 10,
            maximumAutomaticRetryAttempts: 0
        )
        let expectedCacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "cached-after-failure|source",
            renderedHTML: html,
            containerWidth: 280,
            isDarkMode: false
        )

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "cached-after-failure|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "cached-after-failure",
            containerWidth: 280
        )
        XCTAssertTrue(viewModel.didFail)

        _ = await cache.store(
            image: makeImage(color: .systemGreen),
            displayHeight: 206,
            pixelScale: 2,
            for: expectedCacheKey
        )

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "cached-after-failure|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "cached-after-failure",
            containerWidth: 280
        )

        XCTAssertNotNil(viewModel.snapshotImage)
        XCTAssertFalse(viewModel.didFail)
        XCTAssertEqual(viewModel.displayHeight, 206)
        XCTAssertEqual(viewModel.completedCacheKey, expectedCacheKey)
        XCTAssertEqual(renderer.requests.count, 1)
    }

    @MainActor
    func testViewModelSuccessfulRetryClearsFailureState() async throws {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let html = "<html><body>Transient failure preview</body></html>"
        var renderAttempts = 0
        let renderer = StubSnapshotRenderer { request in
            renderAttempts += 1
            if renderAttempts == 1 {
                throw EmailPreviewSnapshotRenderError.timeout
            }
            return EmailPreviewSnapshotResult(
                image: self.makeImage(color: .systemBlue),
                displayHeight: 218,
                pixelScale: 2,
                cacheKey: request.cacheKey
            )
        }
        let viewModel = EmailPreviewSnapshotViewModel(
            cache: cache,
            renderer: renderer,
            retryBackoff: 0.05,
            maximumAutomaticRetryAttempts: 0
        )
        let expectedCacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "transient-message|source",
            renderedHTML: html,
            containerWidth: 280,
            isDarkMode: false
        )

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "transient-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "transient-message",
            containerWidth: 280
        )
        XCTAssertTrue(viewModel.didFail)

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "transient-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "transient-message",
            containerWidth: 280
        )
        XCTAssertEqual(renderer.requests.count, 1)

        try await Task.sleep(nanoseconds: 80_000_000)
        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "transient-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "transient-message",
            containerWidth: 280
        )

        XCTAssertNotNil(viewModel.snapshotImage)
        XCTAssertFalse(viewModel.didFail)
        XCTAssertEqual(viewModel.displayHeight, 218)
        XCTAssertEqual(viewModel.completedCacheKey, expectedCacheKey)
        XCTAssertEqual(renderer.requests.count, 2)
    }

    @MainActor
    func testViewModelPermanentFailuresDoNotImmediatelyRetrySameCacheKey() async throws {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let html = "<html><body>Permanent failure preview</body></html>"
        let renderer = StubSnapshotRenderer { _ in
            throw EmailPreviewSnapshotRenderError.timeout
        }
        let viewModel = EmailPreviewSnapshotViewModel(
            cache: cache,
            renderer: renderer,
            retryBackoff: 0.05,
            maximumAutomaticRetryAttempts: 0
        )

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "permanent-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "permanent-message",
            containerWidth: 280
        )
        XCTAssertTrue(viewModel.didFail)
        XCTAssertEqual(renderer.requests.count, 1)

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "permanent-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "permanent-message",
            containerWidth: 280
        )
        XCTAssertEqual(renderer.requests.count, 1)

        try await Task.sleep(nanoseconds: 80_000_000)
        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "permanent-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "permanent-message",
            containerWidth: 280
        )
        XCTAssertEqual(renderer.requests.count, 2)

        await viewModel.loadSnapshot(
            htmlContent: html,
            previewCacheKey: "permanent-message|source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "permanent-message",
            containerWidth: 280
        )
        XCTAssertEqual(renderer.requests.count, 2)
        XCTAssertTrue(viewModel.didFail)
        XCTAssertNil(viewModel.completedCacheKey)
    }

    @MainActor
    func testViewModelRetryForFailedCacheKeySurvivesDifferentCacheKeySuccess() async throws {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let failedHTML = "<html><body>Failed preview</body></html>"
        let successfulHTML = "<html><body>Successful preview</body></html>"
        var failedRenderAttempts = 0
        let renderer = StubSnapshotRenderer { request in
            if request.html == failedHTML {
                failedRenderAttempts += 1
                if failedRenderAttempts == 1 {
                    throw EmailPreviewSnapshotRenderError.timeout
                }
            }

            return EmailPreviewSnapshotResult(
                image: self.makeImage(color: request.html == failedHTML ? .systemBlue : .systemGreen),
                displayHeight: request.html == failedHTML ? 218 : 206,
                pixelScale: 2,
                cacheKey: request.cacheKey
            )
        }
        let viewModel = EmailPreviewSnapshotViewModel(
            cache: cache,
            renderer: renderer,
            retryBackoff: 0.05,
            maximumAutomaticRetryAttempts: 1
        )
        let failedCacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "retry-message|failed-source",
            renderedHTML: failedHTML,
            containerWidth: 280,
            isDarkMode: false
        )
        let successfulCacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "retry-message|successful-source",
            renderedHTML: successfulHTML,
            containerWidth: 280,
            isDarkMode: false
        )

        await viewModel.loadSnapshot(
            htmlContent: failedHTML,
            previewCacheKey: "retry-message|failed-source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "retry-message",
            containerWidth: 280
        )
        XCTAssertTrue(viewModel.didFail)
        XCTAssertEqual(failedRenderAttempts, 1)
        XCTAssertEqual(viewModel.retryGeneration, 0)

        await viewModel.loadSnapshot(
            htmlContent: successfulHTML,
            previewCacheKey: "retry-message|successful-source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "retry-message",
            containerWidth: 280
        )
        XCTAssertFalse(viewModel.didFail)
        XCTAssertEqual(viewModel.completedCacheKey, successfulCacheKey)

        await viewModel.loadSnapshot(
            htmlContent: failedHTML,
            previewCacheKey: "retry-message|failed-source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "retry-message",
            containerWidth: 280
        )
        XCTAssertTrue(viewModel.didFail)
        XCTAssertEqual(failedRenderAttempts, 1)
        XCTAssertEqual(viewModel.retryGeneration, 0)

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(viewModel.retryGeneration, 1)

        await viewModel.loadSnapshot(
            htmlContent: failedHTML,
            previewCacheKey: "retry-message|failed-source",
            isDarkMode: false,
            senderEmail: nil,
            message: nil,
            messageId: "retry-message",
            containerWidth: 280
        )

        XCTAssertNotNil(viewModel.snapshotImage)
        XCTAssertFalse(viewModel.didFail)
        XCTAssertEqual(viewModel.displayHeight, 218)
        XCTAssertEqual(viewModel.completedCacheKey, failedCacheKey)
        XCTAssertEqual(failedRenderAttempts, 2)
    }

    @MainActor
    func testViewModelCancellationDoesNotUpdateStaleState() async throws {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let html = "<html><body>Cancelled preview</body></html>"
        let renderer = DelayedSnapshotRenderer()
        let viewModel = EmailPreviewSnapshotViewModel(cache: cache, renderer: renderer)
        let renderStarted = expectation(description: "render started")
        renderer.onStart = {
            renderStarted.fulfill()
        }

        let task = Task { @MainActor in
            await viewModel.loadSnapshot(
                htmlContent: html,
                previewCacheKey: "cancelled-message|source",
                isDarkMode: false,
                senderEmail: nil,
                message: nil,
                messageId: "cancelled-message",
                containerWidth: 280
            )
        }

        await fulfillment(of: [renderStarted], timeout: 1.0)
        let request = try XCTUnwrap(renderer.requests.first)
        task.cancel()
        renderer.succeed(
            with: EmailPreviewSnapshotResult(
                image: makeImage(color: .systemOrange),
                displayHeight: 220,
                pixelScale: 2,
                cacheKey: request.cacheKey
            )
        )
        await task.value

        XCTAssertNil(viewModel.snapshotImage)
        XCTAssertNil(viewModel.completedCacheKey)
        XCTAssertFalse(viewModel.didFail)
        let staleCachedSnapshot = await cache.load(for: request.cacheKey)
        XCTAssertNil(staleCachedSnapshot)
        let counts = EmailPreviewSnapshotDiagnostics.countsForTesting()
        XCTAssertEqual(counts.renderSuccesses, 0)
        XCTAssertEqual(counts.renderFailures, 0)
    }

    @MainActor
    func testViewModelKeepsNewerSnapshotWhenOlderRenderCompletesLast() async throws {
        EmailPreviewSnapshotDiagnostics.resetForTesting()

        let cache = EmailPreviewSnapshotCache(cacheDirectory: tempDirectory)
        let firstHTML = "<html><body>First delayed preview</body></html>"
        let secondHTML = "<html><body>Second current preview</body></html>"
        let renderer = KeyedDelayedSnapshotRenderer()
        let viewModel = EmailPreviewSnapshotViewModel(cache: cache, renderer: renderer)
        let firstStarted = expectation(description: "first render started")
        let secondStarted = expectation(description: "second render started")
        var firstCacheKey: String?
        var secondCacheKey: String?
        renderer.onStart = { request in
            if request.html == firstHTML {
                firstCacheKey = request.cacheKey
                firstStarted.fulfill()
            } else if request.html == secondHTML {
                secondCacheKey = request.cacheKey
                secondStarted.fulfill()
            }
        }

        let firstTask = Task { @MainActor in
            await viewModel.loadSnapshot(
                htmlContent: firstHTML,
                previewCacheKey: "stale-message|first-source",
                isDarkMode: false,
                senderEmail: nil,
                message: nil,
                messageId: "stale-message",
                containerWidth: 280
            )
        }
        await fulfillment(of: [firstStarted], timeout: 1.0)

        let secondTask = Task { @MainActor in
            await viewModel.loadSnapshot(
                htmlContent: secondHTML,
                previewCacheKey: "stale-message|second-source",
                isDarkMode: false,
                senderEmail: nil,
                message: nil,
                messageId: "stale-message",
                containerWidth: 280
            )
        }
        await fulfillment(of: [secondStarted], timeout: 1.0)

        let resolvedSecondCacheKey = try XCTUnwrap(secondCacheKey)
        renderer.succeed(
            cacheKey: resolvedSecondCacheKey,
            image: makeImage(color: .systemGreen),
            displayHeight: 224
        )
        await secondTask.value

        XCTAssertEqual(viewModel.completedCacheKey, resolvedSecondCacheKey)
        XCTAssertEqual(viewModel.displayHeight, 224)
        let currentPixel = try XCTUnwrap(
            rgbaPixel(in: try XCTUnwrap(viewModel.snapshotImage), at: CGPoint(x: 10, y: 10))
        )
        XCTAssertGreaterThan(currentPixel.green, currentPixel.red)

        let resolvedFirstCacheKey = try XCTUnwrap(firstCacheKey)
        renderer.succeed(
            cacheKey: resolvedFirstCacheKey,
            image: makeImage(color: .systemOrange),
            displayHeight: 180
        )
        await firstTask.value

        XCTAssertEqual(viewModel.completedCacheKey, resolvedSecondCacheKey)
        XCTAssertEqual(viewModel.displayHeight, 224)
        let finalPixel = try XCTUnwrap(
            rgbaPixel(in: try XCTUnwrap(viewModel.snapshotImage), at: CGPoint(x: 10, y: 10))
        )
        XCTAssertGreaterThan(finalPixel.green, finalPixel.red)
        let staleCachedSnapshot = await cache.load(for: resolvedFirstCacheKey)
        let currentCachedSnapshot = await cache.load(for: resolvedSecondCacheKey)
        XCTAssertNil(staleCachedSnapshot)
        XCTAssertNotNil(currentCachedSnapshot)
    }

    @MainActor
    func testSnapshotRenderSchedulerRespectsMaxConcurrency() async throws {
        let scheduler = EmailPreviewSnapshotRenderScheduler(maxConcurrentRenders: 2)
        let firstStarted = expectation(description: "first render started")
        let secondStarted = expectation(description: "second render started")
        let thirdStarted = expectation(description: "third render started")
        var continuations: [String: CheckedContinuation<EmailPreviewSnapshotResult, Error>] = [:]
        var activeCount = 0
        var maxActiveCount = 0
        var startedKeys: [String] = []

        func scheduledTask(cacheKey: String) -> Task<EmailPreviewSnapshotResult, Error> {
            Task { @MainActor in
                try await scheduler.render(request: makeSnapshotRequest(cacheKey: cacheKey)) {
                    activeCount += 1
                    maxActiveCount = max(maxActiveCount, activeCount)
                    startedKeys.append(cacheKey)
                    defer { activeCount -= 1 }

                    return try await withCheckedThrowingContinuation { continuation in
                        continuations[cacheKey] = continuation
                        switch cacheKey {
                        case "scheduler-first":
                            firstStarted.fulfill()
                        case "scheduler-second":
                            secondStarted.fulfill()
                        case "scheduler-third":
                            thirdStarted.fulfill()
                        default:
                            break
                        }
                    }
                }
            }
        }

        let firstTask = scheduledTask(cacheKey: "scheduler-first")
        let secondTask = scheduledTask(cacheKey: "scheduler-second")
        let thirdTask = scheduledTask(cacheKey: "scheduler-third")

        await fulfillment(of: [firstStarted, secondStarted], timeout: 1.0)
        XCTAssertEqual(startedKeys, ["scheduler-first", "scheduler-second"])
        XCTAssertEqual(maxActiveCount, 2)

        continuations["scheduler-first"]?.resume(
            returning: makeSnapshotResult(cacheKey: "scheduler-first", color: .systemRed)
        )
        await fulfillment(of: [thirdStarted], timeout: 1.0)
        XCTAssertEqual(startedKeys, ["scheduler-first", "scheduler-second", "scheduler-third"])
        XCTAssertEqual(maxActiveCount, 2)

        continuations["scheduler-second"]?.resume(
            returning: makeSnapshotResult(cacheKey: "scheduler-second", color: .systemBlue)
        )
        continuations["scheduler-third"]?.resume(
            returning: makeSnapshotResult(cacheKey: "scheduler-third", color: .systemGreen)
        )

        _ = try await firstTask.value
        _ = try await secondTask.value
        _ = try await thirdTask.value
        XCTAssertEqual(maxActiveCount, 2)
    }

    @MainActor
    func testSnapshotRenderSchedulerCoalescesSameCacheKeyRequests() async throws {
        let scheduler = EmailPreviewSnapshotRenderScheduler(maxConcurrentRenders: 1)
        let renderStarted = expectation(description: "coalesced render started")
        var continuation: CheckedContinuation<EmailPreviewSnapshotResult, Error>?
        var startCount = 0
        let request = makeSnapshotRequest(cacheKey: "coalesced-snapshot")

        func scheduledTask() -> Task<EmailPreviewSnapshotResult, Error> {
            Task { @MainActor in
                try await scheduler.render(request: request) {
                    startCount += 1
                    return try await withCheckedThrowingContinuation { renderContinuation in
                        continuation = renderContinuation
                        renderStarted.fulfill()
                    }
                }
            }
        }

        let firstTask = scheduledTask()
        let secondTask = scheduledTask()

        await fulfillment(of: [renderStarted], timeout: 1.0)
        await Task.yield()
        XCTAssertEqual(startCount, 1)

        continuation?.resume(
            returning: makeSnapshotResult(cacheKey: request.cacheKey, color: .systemPurple)
        )

        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value
        XCTAssertEqual(firstResult.cacheKey, request.cacheKey)
        XCTAssertEqual(secondResult.cacheKey, request.cacheKey)
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testSnapshotRenderSchedulerCancelsQueuedRenderBeforeOperationStarts() async throws {
        let scheduler = EmailPreviewSnapshotRenderScheduler(maxConcurrentRenders: 1)
        let firstStarted = expectation(description: "first render started")
        var firstContinuation: CheckedContinuation<EmailPreviewSnapshotResult, Error>?
        var startedKeys: [String] = []

        let firstTask = Task { @MainActor in
            try await scheduler.render(request: makeSnapshotRequest(cacheKey: "queued-first")) {
                startedKeys.append("queued-first")
                return try await withCheckedThrowingContinuation { continuation in
                    firstContinuation = continuation
                    firstStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1.0)

        let queuedTask = Task { @MainActor in
            try await scheduler.render(request: makeSnapshotRequest(cacheKey: "queued-cancelled")) {
                startedKeys.append("queued-cancelled")
                return self.makeSnapshotResult(cacheKey: "queued-cancelled", color: .systemOrange)
            }
        }
        await Task.yield()
        queuedTask.cancel()

        do {
            _ = try await queuedTask.value
            XCTFail("Expected queued snapshot render to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(startedKeys, ["queued-first"])
        firstContinuation?.resume(
            returning: makeSnapshotResult(cacheKey: "queued-first", color: .systemBlue)
        )
        _ = try await firstTask.value
        XCTAssertEqual(startedKeys, ["queued-first"])
    }

    // WebKit's content processes spawn lazily on the first full render in the
    // test host, and on a loaded CI runner that cold start alone can exceed
    // the renderer's 5s budget (PR #115's run lost
    // testRendererKeepsShortPreviewAtDefaultHeight to it at 5.165s). Warm once
    // per process so the assertion renders measure warm-path behavior only.
    @MainActor
    private static var hasWarmedRenderer = false

    @MainActor
    private static func warmUpRendererIfNeeded() async {
        guard !hasWarmedRenderer else { return }
        hasWarmedRenderer = true

        let request = EmailPreviewSnapshotRequest(
            html: "<html><body>warm-up</body></html>",
            cacheKey: "renderer-warm-up",
            containerWidth: 280,
            isDarkMode: false,
            senderEmail: nil,
            message: nil
        )
        // Even if a cold spawn consumes this render's own 5s timeout, the
        // spawn it forces leaves WebKit warm for the real renders below.
        _ = try? await EmailPreviewSnapshotRenderer.shared.render(request: request)
    }

    @MainActor
    func testRendererCancellationStopsSnapshotRender() async {
        let request = EmailPreviewSnapshotRequest(
            html: "<html><body><div style=\"height: 200px\">Preview</div></body></html>",
            cacheKey: "cancelled-render",
            containerWidth: 280,
            isDarkMode: false,
            senderEmail: nil,
            message: nil
        )

        let task = Task { @MainActor in
            try await EmailPreviewSnapshotRenderer.shared.render(request: request)
        }

        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancelled snapshot render to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    @MainActor
    func testRendererKeepsShortPreviewAtDefaultHeight() async throws {
        await Self.warmUpRendererIfNeeded()

        let request = EmailPreviewSnapshotRequest(
            html: """
            <html>
            <head>
                <style>
                    html, body { margin: 0; padding: 0; min-height: 1px; }
                    .preview { height: 24px; width: 120px; }
                </style>
            </head>
            <body><div class="preview">Short preview</div></body>
            </html>
            """,
            cacheKey: "short-preview",
            containerWidth: 280,
            isDarkMode: false,
            senderEmail: nil,
            message: nil
        )

        let result = try await EmailPreviewSnapshotRenderer.shared.render(request: request)

        XCTAssertEqual(result.displayHeight, HTMLPreviewSizing.defaultPreviewHeight)
        XCTAssertLessThan(result.displayHeight, HTMLPreviewSizing.maximumPreviewHeight)
    }

    @MainActor
    func testRendererPaintsLowerRegionForTallPreview() async throws {
        await Self.warmUpRendererIfNeeded()

        let request = EmailPreviewSnapshotRequest(
            html: """
            <div style="height: 420px; background: #ffffff;"></div>
            <div style="height: 180px; background: #d92727;"></div>
            """,
            cacheKey: "tall-preview",
            containerWidth: 280,
            isDarkMode: false,
            senderEmail: nil,
            message: nil
        )

        let result = try await EmailPreviewSnapshotRenderer.shared.render(request: request)

        XCTAssertGreaterThan(result.displayHeight, HTMLPreviewSizing.defaultPreviewHeight)
        XCTAssertLessThanOrEqual(result.displayHeight, HTMLPreviewSizing.maximumPreviewHeight)

        let bottomPixel = try XCTUnwrap(
            rgbaPixel(
                in: result.image,
                at: CGPoint(x: result.image.size.width / 2, y: result.displayHeight - 24)
            )
        )
        XCTAssertGreaterThan(bottomPixel.red, 0.6)
        XCTAssertLessThan(bottomPixel.green, 0.35)
        XCTAssertLessThan(bottomPixel.blue, 0.35)
        XCTAssertGreaterThan(bottomPixel.alpha, 0.9)
    }

    private func makeImage(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }

    private func makeSnapshotRequest(cacheKey: String) -> EmailPreviewSnapshotRequest {
        EmailPreviewSnapshotRequest(
            html: "<html><body>\(cacheKey)</body></html>",
            cacheKey: cacheKey,
            containerWidth: 280,
            isDarkMode: false,
            senderEmail: nil,
            message: nil
        )
    }

    private func makeSnapshotResult(
        cacheKey: String,
        color: UIColor,
        displayHeight: CGFloat = HTMLPreviewSizing.defaultPreviewHeight
    ) -> EmailPreviewSnapshotResult {
        EmailPreviewSnapshotResult(
            image: makeImage(color: color),
            displayHeight: displayHeight,
            pixelScale: 2,
            cacheKey: cacheKey
        )
    }

    private func rgbaPixel(
        in image: UIImage,
        at point: CGPoint
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard point.x >= 0,
              point.y >= 0,
              point.x < image.size.width,
              point.y < image.size.height else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        UIGraphicsPushContext(context)
        image.draw(at: CGPoint(x: -point.x, y: -point.y))
        UIGraphicsPopContext()

        return (
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: CGFloat(pixel[3]) / 255
        )
    }
}

@MainActor
private final class StubSnapshotRenderer: EmailPreviewSnapshotRendering {
    enum Error: Swift.Error {
        case unexpectedRender
    }

    private let handler: @MainActor (EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult
    private(set) var requests: [EmailPreviewSnapshotRequest] = []

    init(handler: @escaping @MainActor (EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult) {
        self.handler = handler
    }

    func render(request: EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult {
        requests.append(request)
        return try await handler(request)
    }
}

@MainActor
private final class DelayedSnapshotRenderer: EmailPreviewSnapshotRendering {
    var onStart: (() -> Void)?
    private(set) var requests: [EmailPreviewSnapshotRequest] = []
    private var continuation: CheckedContinuation<EmailPreviewSnapshotResult, Error>?

    func render(request: EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult {
        requests.append(request)
        onStart?()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(with result: EmailPreviewSnapshotResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class KeyedDelayedSnapshotRenderer: EmailPreviewSnapshotRendering {
    var onStart: ((EmailPreviewSnapshotRequest) -> Void)?
    private(set) var requests: [EmailPreviewSnapshotRequest] = []
    private var continuations: [String: CheckedContinuation<EmailPreviewSnapshotResult, Error>] = [:]

    func render(request: EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request.cacheKey] = continuation
            onStart?(request)
        }
    }

    func succeed(
        cacheKey: String,
        image: UIImage,
        displayHeight: CGFloat
    ) {
        continuations[cacheKey]?.resume(
            returning: EmailPreviewSnapshotResult(
                image: image,
                displayHeight: displayHeight,
                pixelScale: image.scale,
                cacheKey: cacheKey
            )
        )
        continuations[cacheKey] = nil
    }
}
