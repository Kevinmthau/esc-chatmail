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
        resetFeatureFlags()
    }

    override func tearDown() {
        resetFeatureFlags()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func testFeatureFlagsDefaultToSnapshotsDisabledAndFallbackEnabled() {
        XCTAssertFalse(EmailPreviewSnapshotFeatureFlag.isEnabled)
        XCTAssertTrue(EmailPreviewSnapshotFeatureFlag.fallbackToLiveWebView)
    }

    func testFeatureFlagsReadExplicitValues() {
        UserDefaults.standard.set(true, forKey: "EmailPreviewSnapshots_Enabled")
        UserDefaults.standard.set(false, forKey: "EmailPreviewSnapshots_FallbackToLiveWebView")

        XCTAssertTrue(EmailPreviewSnapshotFeatureFlag.isEnabled)
        XCTAssertFalse(EmailPreviewSnapshotFeatureFlag.fallbackToLiveWebView)
    }

    func testSnapshotAppearanceUsesExplicitRequestColorScheme() {
        XCTAssertEqual(EmailPreviewSnapshotAppearance.userInterfaceStyle(isDarkMode: false), .light)
        XCTAssertEqual(EmailPreviewSnapshotAppearance.userInterfaceStyle(isDarkMode: true), .dark)
    }

    func testCacheKeyChangesWithWidthDarkModeAndRendererVersion() {
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

        XCTAssertNotEqual(base, wider)
        XCTAssertNotEqual(base, dark)
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

    private func resetFeatureFlags() {
        UserDefaults.standard.removeObject(forKey: "EmailPreviewSnapshots_Enabled")
        UserDefaults.standard.removeObject(forKey: "EmailPreviewSnapshots_FallbackToLiveWebView")
    }
}
