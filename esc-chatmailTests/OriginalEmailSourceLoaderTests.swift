import XCTest
import UIKit
@testable import esc_chatmail

final class OriginalEmailSourceLoaderTests: XCTestCase {
    private var contentHandler: HTMLContentHandler!
    private var recoveryService: MutableRecoveryService!
    private var loader: OriginalEmailSourceLoader!

    override func setUp() {
        super.setUp()
        contentHandler = HTMLContentHandler()
        recoveryService = MutableRecoveryService(contentHandler: contentHandler)
        loader = makeLoader()
    }

    override func tearDown() {
        loader = nil
        recoveryService = nil
        contentHandler = nil
        super.tearDown()
    }

    func testLoadOriginalEmailSource_returnsStoredHTMLForPlainFirstMultipartFixture() async throws {
        let messageId = "original-plain-first-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let plainURLDump = """
        https://tracking.example.com/a
        https://tracking.example.com/b
        Reserve your table
        """
        let html = newsletterHTML(title: "Reserve your table")
        _ = contentHandler.saveHTML(html, for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: plainURLDump,
            senderEmail: "reservations@example.com",
            subject: "Reserve your table",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceKind, .html)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("Reserve your table") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/a") == true)
    }

    func testLoadOriginalEmailSource_returnsStoredHTMLForHTMLFirstMultipartFixture() async throws {
        let messageId = "original-html-first-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let plainURLDump = """
        https://tracking.example.com/a
        https://tracking.example.com/b
        View offer
        """
        let html = newsletterHTML(title: "View offer")
        _ = contentHandler.saveHTML(html, for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: plainURLDump,
            senderEmail: "reservations@example.com",
            subject: "View offer",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceKind, .html)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("View offer") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/a") == true)
    }

    func testLoadOriginalEmailSource_fullNewsletterModelContainsOriginalHTMLMarkers() async throws {
        let messageId = "original-markers-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(newsletterHTML(title: "Book a suite"), for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "https://tracking.example.com/a\nBook a suite",
            senderEmail: "reservations@example.com",
            subject: "Book a suite",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)
        let html = try XCTUnwrap(source.html)

        XCTAssertTrue(html.contains("<!DOCTYPE"))
        XCTAssertTrue(html.lowercased().contains("<html"))
        XCTAssertTrue(html.lowercased().contains("<table"))
        XCTAssertTrue(html.lowercased().contains("<img"))
        XCTAssertTrue(html.contains("href=\"https://example.com/cta\""))
    }

    func testLoadOriginalEmailSource_repeatedLoadReusesRenderedOriginalVariant() async throws {
        let messageId = "original-repeated-load-\(UUID().uuidString)"
        let renderedCache = RenderedMessageCache()
        let loader = makeLoader(renderedMessageCache: renderedCache)
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(newsletterHTML(title: "Stable original"), for: messageId)

        let firstSource = await loader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Stable original",
            senderEmail: "newsletter@example.com",
            subject: "Stable original"
        )
        let secondSource = await loader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Stable original",
            senderEmail: "newsletter@example.com",
            subject: "Stable original"
        )

        let first = try XCTUnwrap(firstSource)
        let second = try XCTUnwrap(secondSource)
        let cachedArtifacts = await renderedCache.artifacts(
            messageId: messageId,
            sourceSignature: first.sourceSignature
        )
        let artifacts = try XCTUnwrap(cachedArtifacts)

        XCTAssertEqual(first.sourceSignature, second.sourceSignature)
        XCTAssertEqual(first.html, second.html)
        XCTAssertEqual(artifacts.wrappedOriginalHTMLByVariant.count, 1)
    }

    func testLoadOriginalEmailSource_sourceSignatureChangeReloadsRenderedHTML() async throws {
        let messageId = "original-source-change-\(UUID().uuidString)"
        let renderedCache = RenderedMessageCache()
        let loader = makeLoader(renderedMessageCache: renderedCache)
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(newsletterHTML(title: "First original"), for: messageId)
        let firstSource = await loader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "First original",
            senderEmail: "newsletter@example.com",
            subject: "Original"
        )
        let first = try XCTUnwrap(firstSource)

        _ = contentHandler.saveHTML(newsletterHTML(title: "Second original with changed source"), for: messageId)
        let secondSource = await loader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "First original",
            senderEmail: "newsletter@example.com",
            subject: "Original"
        )
        let second = try XCTUnwrap(secondSource)

        XCTAssertNotEqual(first.sourceSignature, second.sourceSignature)
        XCTAssertTrue(first.html?.contains("First original") == true)
        XCTAssertFalse(first.html?.contains("Second original with changed source") == true)
        XCTAssertTrue(second.html?.contains("Second original with changed source") == true)
        XCTAssertFalse(second.html?.contains("First original") == true)
        let firstArtifacts = await renderedCache.artifacts(
            messageId: messageId,
            sourceSignature: first.sourceSignature
        )
        let secondArtifacts = await renderedCache.artifacts(
            messageId: messageId,
            sourceSignature: second.sourceSignature
        )
        XCTAssertNotNil(firstArtifacts)
        XCTAssertNotNil(secondArtifacts)
    }

    func testLoadOriginalEmailSource_usesLightColorSchemeForFullFidelity() async throws {
        let messageId = "original-light-fidelity-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(newsletterHTML(title: "Author colors"), for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Author colors",
            senderEmail: "newsletter@example.com",
            subject: "Author colors",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)
        let html = try XCTUnwrap(source.html)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertTrue(html.contains(#"<meta name="color-scheme" content="light">"#))
        XCTAssertTrue(html.contains("color-scheme: light;"))
        XCTAssertTrue(html.lowercased().contains("<table"))
        XCTAssertTrue(html.lowercased().contains("<img"))
        XCTAssertTrue(html.contains("href=\"https://example.com/cta\""))
        XCTAssertFalse(html.contains("#1c1c1e"))
    }

    func testLoadOriginalEmailSource_plainTextOnlyRendersNativePlainText() async throws {
        let messageId = "original-plain-only-\(UUID().uuidString)"

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain text only\nhttps://example.com",
            senderEmail: "person@example.com",
            subject: "Plain",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .nativePlainText)
        XCTAssertEqual(source.sourceKind, .plainText)
        XCTAssertEqual(source.plainText, "Plain text only\nhttps://example.com")
        XCTAssertNil(source.html)
    }

    func testLoadOriginalEmailSource_unusableStoredHTMLFallsBackToNativePlainText() async throws {
        let messageId = "original-unusable-html-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Visible plain text fallback",
            senderEmail: "person@example.com",
            subject: "Fallback",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .nativePlainText)
        XCTAssertEqual(source.sourceKind, .plainText)
        XCTAssertTrue(source.hasHTMLSource)
        XCTAssertEqual(source.plainText, "Visible plain text fallback")
        XCTAssertNil(source.html)
    }

    func testLoadOriginalEmailSource_unusableStoredHTMLRetriesRecoveryBeforePlainTextFallback() async throws {
        let messageId = "original-unusable-html-recovery-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )
        recoveryService.setHTML(newsletterHTML(title: "Recovered original"), for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "https://tracking.example.com/open\nRecovered original",
            senderEmail: "newsletter@example.com",
            subject: "Recovered",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceKind, .recoveredHTML)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("Recovered original") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/open") == true)
    }

    func testLoadOriginalEmailSource_unusableMessageFileContinuesToStorageURIHTML() async throws {
        let messageId = "original-storage-fallback-\(UUID().uuidString)"
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(messageId)-storage.html")
        defer {
            contentHandler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: storageURL)
        }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )
        try newsletterHTML(title: "Storage original").write(to: storageURL, atomically: true, encoding: .utf8)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: storageURL.path,
            bodyText: "https://tracking.example.com/open\nStorage original",
            senderEmail: "newsletter@example.com",
            subject: "Storage",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceLocation, .storageURI)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("Storage original") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/open") == true)
    }

    func testLoadOriginalEmailSource_rawSourceFallbackDoesNotPointToStaleMessageFile() async throws {
        let messageId = "original-raw-fallback-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: rawMultipartAlternativeSource(
                plainText: "https://tracking.example.com/open\nRaw original",
                html: newsletterHTML(title: "Raw original")
            ),
            senderEmail: "newsletter@example.com",
            subject: "Raw",
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceLocation, .rawSourceHTML)
        XCTAssertFalse(source.shouldPointBodyStorageURIAtMessageFile)
        XCTAssertTrue(source.html?.contains("Raw original") == true)
    }

    func testLoadOriginalEmailSource_rawEmbeddedHTMLSavesMessageFileAndSkipsRecovery() async throws {
        let messageId = "original-klaviyo-raw-source-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let firstSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: klaviyoStyleRawMultipartAlternativeSource(),
            senderEmail: "newsletter@flamingoestate.example",
            subject: "A bright note from Flamingo Estate",
            timeout: 5.0
        )
        let first = try XCTUnwrap(firstSource)

        XCTAssertEqual(first.presentation, .html)
        XCTAssertEqual(first.sourceKind, .html)
        XCTAssertEqual(first.sourceLocation, .rawSourceHTML)
        XCTAssertTrue(first.html?.contains("Roma Heirloom Tomato Candle") == true)
        XCTAssertFalse(first.html?.contains("Content-Type: text/plain") == true)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("Roma Heirloom Tomato Candle") == true)
        XCTAssertEqual(recoveryService.recoveryRequestCount, 0)

        let secondSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@flamingoestate.example",
            subject: "A bright note from Flamingo Estate",
            timeout: 5.0
        )
        let second = try XCTUnwrap(secondSource)

        XCTAssertEqual(second.presentation, .html)
        XCTAssertEqual(second.sourceKind, .html)
        XCTAssertEqual(second.sourceLocation, .messageFile)
        XCTAssertTrue(second.html?.contains("Roma Heirloom Tomato Candle") == true)
        XCTAssertEqual(recoveryService.recoveryRequestCount, 0)
    }

    func testLoadOriginalEmailSource_recoveryUpgradesPlainTextWithoutStaleCache() async throws {
        let messageId = "original-recovery-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let firstSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback before recovery",
            senderEmail: "newsletter@example.com",
            subject: "Recovered",
            timeout: 5.0
        )
        let first = try XCTUnwrap(firstSource)
        XCTAssertEqual(first.presentation, .nativePlainText)

        recoveryService.setHTML(newsletterHTML(title: "Recovered HTML"), for: messageId)

        let recoveredSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback before recovery",
            senderEmail: "newsletter@example.com",
            subject: "Recovered",
            timeout: 5.0
        )
        let recovered = try XCTUnwrap(recoveredSource)

        XCTAssertEqual(recovered.presentation, .html)
        XCTAssertEqual(recovered.sourceKind, .recoveredHTML)
        XCTAssertTrue(recovered.html?.contains("Recovered HTML") == true)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("Recovered HTML") == true)
    }

    func testLoadOriginalEmailSourceToCompletionReturnsRecoveredHTMLAfterSoftTimeout() async throws {
        let messageId = "original-timeout-recovery-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let delayedRecovery = DelayedRecoveryService(
            contentHandler: contentHandler,
            html: newsletterHTML(title: "Delayed recovered original"),
            delayNanoseconds: 80_000_000
        )
        let delayedLoader = OriginalEmailSourceLoader(
            canonicalContentLoader: CanonicalEmailContentLoader(
                contentHandler: contentHandler,
                recoveryService: delayedRecovery
            ),
            htmlContentLoader: HTMLContentLoader(contentHandler: contentHandler, sanitizer: .shared)
        )

        let timedOut = await delayedLoader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Delayed",
            timeout: 0.01
        )
        XCTAssertNil(timedOut)

        let recoveredSource = await delayedLoader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Delayed"
        )
        let recovered = try XCTUnwrap(recoveredSource)

        XCTAssertEqual(recovered.presentation, .html)
        XCTAssertEqual(recovered.sourceKind, .recoveredHTML)
        XCTAssertTrue(recovered.html?.contains("Delayed recovered original") == true)
    }

    func testLoadOriginalEmailSourceRetryReadsRecoveredHTMLAfterSoftTimeoutWarmsCache() async throws {
        let messageId = "original-timeout-warmed-retry-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let delayedRecovery = DelayedRecoveryService(
            contentHandler: contentHandler,
            html: newsletterHTML(title: "Warm recovered original"),
            delayNanoseconds: 80_000_000
        )
        let delayedLoader = OriginalEmailSourceLoader(
            canonicalContentLoader: CanonicalEmailContentLoader(
                contentHandler: contentHandler,
                recoveryService: delayedRecovery
            ),
            htmlContentLoader: HTMLContentLoader(contentHandler: contentHandler, sanitizer: .shared)
        )

        let timedOut = await delayedLoader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Delayed",
            timeout: 0.01
        )
        XCTAssertNil(timedOut)

        try await Task.sleep(nanoseconds: 120_000_000)

        let retrySource = await delayedLoader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Delayed",
            timeout: 0.5
        )
        let retry = try XCTUnwrap(retrySource)

        XCTAssertEqual(retry.presentation, .html)
        XCTAssertEqual(retry.sourceKind, .html)
        XCTAssertEqual(retry.sourceLocation, .messageFile)
        XCTAssertTrue(retry.html?.contains("Warm recovered original") == true)
    }

    func testLoadOriginalEmailSourceToCompletionReturnsNilForTrueUnavailableContent() async {
        let messageId = "original-unavailable-\(UUID().uuidString)"

        let loadedSource = await loader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "person@example.com",
            subject: "Missing"
        )

        XCTAssertNil(loadedSource)
    }

    func testWarmOriginalEmailSourceMakesLaterOpenAnInstantCacheHit() async throws {
        let messageId = "warm-original-\(UUID().uuidString)"
        let renderedCache = RenderedMessageCache()
        let loader = makeLoader(renderedMessageCache: renderedCache)
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(newsletterHTML(title: "Warm me"), for: messageId)

        await loader.warmOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Warm me",
            senderEmail: "newsletter@example.com",
            subject: "Warm me"
        )

        let statsAfterWarm = await renderedCache.getStatistics()
        XCTAssertEqual(statsAfterWarm.producedArtifacts, 1, "Warm should prepare and cache the original HTML")
        XCTAssertEqual(recoveryService.recoveryRequestCount, 0, "Warm must never trigger network recovery")

        let openedSource = await loader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Warm me",
            senderEmail: "newsletter@example.com",
            subject: "Warm me"
        )
        let source = try XCTUnwrap(openedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertTrue(source.html?.contains("Warm me") == true)

        let statsAfterOpen = await renderedCache.getStatistics()
        XCTAssertEqual(
            statsAfterOpen.producedArtifacts,
            1,
            "Opening the full view should reuse the warmed cache entry instead of re-preparing"
        )

        let cachedArtifacts = await renderedCache.artifacts(
            messageId: messageId,
            sourceSignature: source.sourceSignature
        )
        let artifacts = try XCTUnwrap(cachedArtifacts)
        XCTAssertEqual(artifacts.wrappedOriginalHTMLByVariant.count, 1)
    }

    func testWarmOriginalEmailSourceDoesNotCachePendingRemoteImageRewrite() async throws {
        let messageId = "warm-pending-rewrite-\(UUID().uuidString)"
        let renderedCache = RenderedMessageCache()
        let imageURL = "https://cdn.example.com/hero.webp?format=auto"
        let html = remoteImageHTML(title: "Needs image rewrite", imageURL: imageURL)
        let imageData = onePixelPNGData()
        let remoteImageAttachmentFallback = HTMLRemoteImageAttachmentFallback { request in
            let headers: [String: String] = [
                "Content-Type": "image/webp",
                "Content-Length": "\(imageData.count)"
            ]
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )
            )

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }
        let loader = makeLoader(
            renderedMessageCache: renderedCache,
            remoteImageAttachmentFallback: remoteImageAttachmentFallback
        )
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(html, for: messageId)

        await loader.warmOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Needs image rewrite",
            senderEmail: "newsletter@example.com",
            subject: "Needs image rewrite"
        )

        let statsAfterWarm = await renderedCache.getStatistics()
        XCTAssertEqual(statsAfterWarm.producedArtifacts, 0, "Warm must not cache first-pass HTML while image rewrites are pending")
        XCTAssertEqual(statsAfterWarm.currentEntryCount, 0)

        _ = await remoteImageAttachmentFallback.inlineAttachmentStyleImages(
            in: html,
            senderEmail: "newsletter@example.com"
        )

        let openedSource = await loader.loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Needs image rewrite",
            senderEmail: "newsletter@example.com",
            subject: "Needs image rewrite"
        )
        let source = try XCTUnwrap(openedSource)
        let openedHTML = try XCTUnwrap(source.html)

        XCTAssertTrue(openedHTML.contains("data:image/"))
        XCTAssertFalse(openedHTML.contains(imageURL))

        let statsAfterOpen = await renderedCache.getStatistics()
        XCTAssertEqual(statsAfterOpen.producedArtifacts, 1)
        XCTAssertEqual(statsAfterOpen.currentEntryCount, 1)
    }

    func testWarmOriginalEmailSourceWithoutLocalHTMLDoesNotRecoverOrCache() async {
        let messageId = "warm-no-recovery-\(UUID().uuidString)"
        let renderedCache = RenderedMessageCache()
        let loader = makeLoader(renderedMessageCache: renderedCache)
        // Recovery HTML is available, but warming must never reach for it.
        recoveryService.setHTML(newsletterHTML(title: "Should not recover"), for: messageId)

        await loader.warmOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain text only, no HTML markup here",
            senderEmail: "person@example.com",
            subject: "No HTML"
        )

        XCTAssertEqual(recoveryService.recoveryRequestCount, 0)
        let stats = await renderedCache.getStatistics()
        XCTAssertEqual(stats.producedArtifacts, 0)
    }

    private func newsletterHTML(title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <body>
          <table role="presentation">
            <tr>
              <td>
                <img src="https://cdn.example.com/hero.jpg" alt="Hero">
                <h1>\(title)</h1>
                <a href="https://example.com/cta">Reserve now</a>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """
    }

    private func remoteImageHTML(title: String, imageURL: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <body>
          <img src="\(imageURL)" alt="Hero">
          <h1>\(title)</h1>
        </body>
        </html>
        """
    }

    private func onePixelPNGData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func rawMultipartAlternativeSource(plainText: String, html: String) -> String {
        """
        From: newsletter@example.com
        To: person@example.com
        Subject: Raw
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="raw-boundary"

        --raw-boundary
        Content-Type: text/plain; charset="UTF-8"

        \(plainText)

        --raw-boundary
        Content-Type: text/html; charset="UTF-8"

        \(html)

        --raw-boundary--
        """
    }

    private func klaviyoStyleRawMultipartAlternativeSource() -> String {
        """
        From: Flamingo Estate <newsletter@flamingoestate.example>
        To: person@example.com
        Subject: A bright note from Flamingo Estate
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="===============728914537882421=="

        --===============728914537882421==
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        Plain fallback should not appear in the original HTML.
        Roma Heirloom Tomato Candle

        --===============728914537882421==
        Content-Transfer-Encoding: quoted-printable
        Content-Type: text/html; charset="UTF-8"

        <!doctype html>
        <html>
        <body>
          <div style=3D"display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">
            A bright note from Flamingo Estate &zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;
          </div>
          <table role=3D"presentation" width=3D"100%">
            <tr>
              <td><img src=3D"https://d3k81ch9hvuctc.cloudfront.net/company/flamingo/header.gif" alt=3D"Flamingo Estate"></td>
            </tr>
            <tr>
              <td>
                <img src=3D"https://cdn.shopify.com/s/files/1/0000/products/tomato-candle.png?v=3D1712345678" alt=3D"Roma Heirloom Tomato Candle">
                <h1>Roma Heirloom Tomato Candle</h1>
                <p>Sun-warmed leaves, garden vines, and a green finish.</p>
              </td>
            </tr>
          </table>
        </body>
        </html>

        --===============728914537882421==--
        """
    }

    private func makeLoader(
        renderedMessageCache: RenderedMessageCache = RenderedMessageCache(),
        remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback = .shared
    ) -> OriginalEmailSourceLoader {
        OriginalEmailSourceLoader(
            canonicalContentLoader: CanonicalEmailContentLoader(
                contentHandler: contentHandler,
                recoveryService: recoveryService
            ),
            htmlContentLoader: HTMLContentLoader(
                contentHandler: contentHandler,
                sanitizer: .shared,
                remoteImageAttachmentFallback: remoteImageAttachmentFallback
            ),
            renderedMessageCache: renderedMessageCache
        )
    }
}

private final class MutableRecoveryService: HTMLContentRecovering, @unchecked Sendable {
    private let lock = NSLock()
    private let contentHandler: HTMLContentHandler
    private var htmlByMessageID: [String: String] = [:]
    private var recoveryRequests = 0

    init(contentHandler: HTMLContentHandler) {
        self.contentHandler = contentHandler
    }

    var recoveryRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recoveryRequests
    }

    func setHTML(_ html: String, for messageId: String) {
        lock.lock()
        htmlByMessageID[messageId] = html
        lock.unlock()
    }

    func recoverHTMLContent(messageId: String) async -> String? {
        lock.lock()
        recoveryRequests += 1
        let html = htmlByMessageID[messageId]
        lock.unlock()

        if let html {
            _ = contentHandler.saveHTML(html, for: messageId)
        }

        return html
    }
}

private final class DelayedRecoveryService: HTMLContentRecovering, @unchecked Sendable {
    private let contentHandler: HTMLContentHandler
    private let html: String?
    private let delayNanoseconds: UInt64

    init(contentHandler: HTMLContentHandler, html: String?, delayNanoseconds: UInt64) {
        self.contentHandler = contentHandler
        self.html = html
        self.delayNanoseconds = delayNanoseconds
    }

    func recoverHTMLContent(messageId: String) async -> String? {
        try? await Task.sleep(nanoseconds: delayNanoseconds)

        if let html {
            _ = contentHandler.saveHTML(html, for: messageId)
        }

        return html
    }
}
