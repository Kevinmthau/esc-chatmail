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

    func testSnapshotAppearanceUsesExplicitRequestColorScheme() {
        XCTAssertEqual(EmailPreviewSnapshotAppearance.userInterfaceStyle(isDarkMode: false), .light)
        XCTAssertEqual(EmailPreviewSnapshotAppearance.userInterfaceStyle(isDarkMode: true), .dark)
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
        XCTAssertEqual(EmailPreviewSnapshotDiagnostics.countsForTesting().cacheHits, 1)
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
        let counts = EmailPreviewSnapshotDiagnostics.countsForTesting()
        XCTAssertEqual(counts.cacheMisses, 1)
        XCTAssertEqual(counts.renderSuccesses, 1)
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
        let expectedCacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "failed-message|source",
            renderedHTML: html,
            containerWidth: 280,
            isDarkMode: false
        )

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
        XCTAssertEqual(viewModel.completedCacheKey, expectedCacheKey)
        let counts = EmailPreviewSnapshotDiagnostics.countsForTesting()
        XCTAssertEqual(counts.renderFailures, 1)
        XCTAssertEqual(counts.timeouts, 1)
        XCTAssertEqual(counts.miniEmailWebViewFallbacks, 1)
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
