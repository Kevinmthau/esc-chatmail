import WebKit
import XCTest
@testable import esc_chatmail

final class FullEmailWebViewPoolBookkeepingTests: XCTestCase {
    func testTouchKeepsMostRecentlyUsedAndDoesNotEvictUnderCapacity() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.touch("b"), [])
        XCTAssertEqual(pool.touch("c"), [])
        XCTAssertEqual(pool.order, ["a", "b", "c"])
    }

    func testTouchEvictsLeastRecentlyUsedOverCapacity() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 2)
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.touch("b"), [])
        // "c" overflows capacity → "a" (LRU) evicted.
        XCTAssertEqual(pool.touch("c"), ["a"])
        XCTAssertEqual(pool.order, ["b", "c"])
    }

    func testReTouchRefreshesRecencySoADifferentEntryIsEvicted() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 2)
        _ = pool.touch("a")
        _ = pool.touch("b")
        // Re-touch "a" → it becomes most-recently-used; "b" is now LRU.
        _ = pool.touch("a")
        XCTAssertEqual(pool.order, ["b", "a"])
        XCTAssertEqual(pool.touch("c"), ["b"])
        XCTAssertEqual(pool.order, ["a", "c"])
    }

    func testTouchIsIdempotentForSameId() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        _ = pool.touch("a")
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.order, ["a"])
    }

    func testRemoveDropsEntry() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        _ = pool.touch("a")
        _ = pool.touch("b")
        pool.remove("a")
        XCTAssertEqual(pool.order, ["b"])
    }

    func testRemoveAllClears() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        _ = pool.touch("a")
        _ = pool.touch("b")
        pool.removeAll()
        XCTAssertEqual(pool.order, [])
    }

    func testCapacityIsAtLeastOne() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 0)
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.touch("b"), ["a"])
        XCTAssertEqual(pool.order, ["b"])
    }
}

final class FullEmailRemoteImageFallbackBookkeepingTests: XCTestCase {
    private func makeRequest(messageId: String = "message-1") -> OriginalEmailWarmRequest {
        OriginalEmailWarmRequest(
            messageId: messageId,
            bodyStorageURI: "file:///tmp/\(messageId).html",
            bodyText: "Body",
            senderEmail: "sender@example.com",
            subject: "Subject"
        )
    }

    func testGenerationStartsAtZero() {
        let bookkeeping = FullEmailRemoteImageFallbackBookkeeping()

        XCTAssertEqual(bookkeeping.generation(for: "message-1"), 0)
        XCTAssertTrue(bookkeeping.isCurrent(messageId: "message-1", generation: 0))
    }

    func testFallbackWarmInvalidatesStartedWarmGeneration() {
        var bookkeeping = FullEmailRemoteImageFallbackBookkeeping()
        let startedGeneration = bookkeeping.generation(for: "message-1")

        bookkeeping.markFallbackWarmed(messageId: "message-1")

        XCTAssertFalse(bookkeeping.isCurrent(messageId: "message-1", generation: startedGeneration))
        XCTAssertTrue(bookkeeping.isCurrent(messageId: "message-1", generation: startedGeneration + 1))
    }

    func testFallbackWarmForDifferentMessageDoesNotInvalidateStartedWarmGeneration() {
        var bookkeeping = FullEmailRemoteImageFallbackBookkeeping()
        let startedGeneration = bookkeeping.generation(for: "message-1")

        bookkeeping.markFallbackWarmed(messageId: "message-2")

        XCTAssertTrue(bookkeeping.isCurrent(messageId: "message-1", generation: startedGeneration))
    }

    func testRememberedWarmContextSurvivesFallbackGenerationBump() {
        var bookkeeping = FullEmailRemoteImageFallbackBookkeeping()
        let request = makeRequest()
        let context = FullEmailRemoteImageFallbackBookkeeping.WarmContext(
            request: request,
            width: 390
        )

        bookkeeping.rememberWarmContext(request: request, width: 390)
        bookkeeping.markFallbackWarmed(messageId: "message-1")

        XCTAssertEqual(bookkeeping.warmContext(for: "message-1"), context)
    }

    func testRemovingWarmContextDropsReplacementRewarmInputs() {
        var bookkeeping = FullEmailRemoteImageFallbackBookkeeping()
        let request = makeRequest()

        bookkeeping.rememberWarmContext(request: request, width: 390)
        bookkeeping.removeWarmContext(messageId: "message-1")
        bookkeeping.markFallbackWarmed(messageId: "message-1")

        XCTAssertNil(bookkeeping.warmContext(for: "message-1"))
    }

    func testRemoveAllWarmContextsDropsReplacementRewarmInputs() {
        var bookkeeping = FullEmailRemoteImageFallbackBookkeeping()

        bookkeeping.rememberWarmContext(request: makeRequest(messageId: "message-1"), width: 390)
        bookkeeping.rememberWarmContext(request: makeRequest(messageId: "message-2"), width: 390)
        bookkeeping.removeAllWarmContexts()

        XCTAssertNil(bookkeeping.warmContext(for: "message-1"))
        XCTAssertNil(bookkeeping.warmContext(for: "message-2"))
    }
}

final class FullEmailPreparedOpenPayloadBookkeepingTests: XCTestCase {
    private func makeKey(
        messageId: String = "message-1",
        sourceSignature: String = "sha256:source",
        html: String = "<html>body</html>",
        width: CGFloat = 390
    ) -> FullEmailWebViewPreRenderKey {
        FullEmailWebViewPreRenderKey.make(
            messageId: messageId,
            sourceSignature: sourceSignature,
            wrappedHTML: html,
            cidAvailabilityFingerprint: "cid:none",
            width: width
        )
    }

    private func makeRequest(
        messageId: String = "message-1",
        subject: String = "Subject"
    ) -> OriginalEmailWarmRequest {
        OriginalEmailWarmRequest(
            messageId: messageId,
            bodyStorageURI: "file:///tmp/\(messageId).html",
            bodyText: "Body",
            senderEmail: "sender@example.com",
            subject: subject
        )
    }

    private func makePayload(
        messageId: String = "message-1",
        sourceSignature: String = "sha256:source",
        html: String = "<html>body</html>"
    ) -> FullEmailOpenPayload {
        FullEmailOpenPayload(
            messageId: messageId,
            sourceSignature: sourceSignature,
            html: html,
            presentation: .html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            checkoutAvailability: .warming
        )
    }

    func testStoreAndReadPreparedPayload() {
        var bookkeeping = FullEmailPreparedOpenPayloadBookkeeping()
        let key = makeKey()
        let request = makeRequest()
        let payload = makePayload()

        bookkeeping.store(key: key, request: request, payload: payload)

        XCTAssertEqual(
            bookkeeping.entry(for: "message-1"),
            FullEmailPreparedOpenPayloadBookkeeping.Entry(
                key: key,
                request: request,
                payload: payload
            )
        )
        XCTAssertEqual(bookkeeping.messageIds, ["message-1"])
    }

    func testStoreReplacesExistingPayloadForMessage() {
        var bookkeeping = FullEmailPreparedOpenPayloadBookkeeping()
        bookkeeping.store(
            key: makeKey(html: "<html>old</html>"),
            request: makeRequest(subject: "Old"),
            payload: makePayload(html: "<html>old</html>")
        )

        let newKey = makeKey(sourceSignature: "sha256:new", html: "<html>new</html>")
        let newRequest = makeRequest(subject: "New")
        let newPayload = makePayload(sourceSignature: "sha256:new", html: "<html>new</html>")
        bookkeeping.store(key: newKey, request: newRequest, payload: newPayload)

        XCTAssertEqual(
            bookkeeping.entry(for: "message-1"),
            FullEmailPreparedOpenPayloadBookkeeping.Entry(
                key: newKey,
                request: newRequest,
                payload: newPayload
            )
        )
        XCTAssertEqual(bookkeeping.messageIds, ["message-1"])
    }

    func testRemoveAndRemoveAllDropPreparedPayloads() {
        var bookkeeping = FullEmailPreparedOpenPayloadBookkeeping()
        bookkeeping.store(
            key: makeKey(messageId: "message-1"),
            request: makeRequest(messageId: "message-1"),
            payload: makePayload(messageId: "message-1")
        )
        bookkeeping.store(
            key: makeKey(messageId: "message-2"),
            request: makeRequest(messageId: "message-2"),
            payload: makePayload(messageId: "message-2")
        )

        bookkeeping.remove("message-1")

        XCTAssertNil(bookkeeping.entry(for: "message-1"))
        XCTAssertNotNil(bookkeeping.entry(for: "message-2"))

        bookkeeping.removeAll()

        XCTAssertTrue(bookkeeping.messageIds.isEmpty)
    }
}

@MainActor
final class FullEmailWebViewManagerPreparedPayloadEvictionTests: XCTestCase {
    func testPayloadOnlyEvictionDropsRemoteImageFallbackWarmContext() async throws {
        let messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerTests-\(UUID().uuidString)"
        )
        let contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        defer {
            try? FileManager.default.removeItem(at: messagesDirectory)
        }

        let firstMessageId = "payload-only-first-\(UUID().uuidString)"
        let secondMessageId = "payload-only-second-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(simpleHTML(title: "First"), for: firstMessageId)
        _ = contentHandler.saveHTML(simpleHTML(title: "Second"), for: secondMessageId)

        let manager = FullEmailWebViewManager(capacity: 1, loader: makeLoader(contentHandler: contentHandler))

        await manager.warm(
            request: makeRequest(messageId: firstMessageId),
            message: nil,
            width: 390
        )

        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: firstMessageId))
        XCTAssertTrue(manager.hasRemoteImageFallbackWarmContextForTesting(messageId: firstMessageId))

        await manager.warm(
            request: makeRequest(messageId: secondMessageId),
            message: nil,
            width: 390
        )

        XCTAssertFalse(manager.hasPreparedPayloadForTesting(messageId: firstMessageId))
        XCTAssertFalse(manager.hasRemoteImageFallbackWarmContextForTesting(messageId: firstMessageId))
        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: secondMessageId))
        XCTAssertTrue(manager.hasRemoteImageFallbackWarmContextForTesting(messageId: secondMessageId))

        manager.clear()
    }

    private func makeLoader(contentHandler: HTMLContentHandler) -> OriginalEmailSourceLoader {
        let recoveryService = NoopHTMLContentRecoveryService()
        return OriginalEmailSourceLoader(
            canonicalContentLoader: CanonicalEmailContentLoader(
                contentHandler: contentHandler,
                recoveryService: recoveryService
            ),
            htmlContentLoader: HTMLContentLoader(
                contentHandler: contentHandler,
                sanitizer: .shared,
                remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback(
                    requestExecutor: { _ in throw URLError(.unsupportedURL) }
                ),
                recoveryService: recoveryService
            ),
            renderedMessageCache: RenderedMessageCache()
        )
    }

    private func makeRequest(messageId: String) -> OriginalEmailWarmRequest {
        OriginalEmailWarmRequest(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Body \(messageId)",
            senderEmail: "sender@example.com",
            subject: "Subject"
        )
    }

    private func simpleHTML(title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>\(title)</h1>
          <p>Prepared full email content.</p>
        </body>
        </html>
        """
    }
}

final class FullEmailWebViewAdoptionPolicyTests: XCTestCase {
    func testAdoptionIsEnabledByDefault() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [:]
            )
        )
    }

    func testDisableLaunchArgumentDisablesAdoption() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [FullEmailWebViewAdoptionPolicy.disableLaunchArgument],
                environment: [:]
            )
        )
    }

    func testDisableEnvironmentVariableDisablesAdoptionWhenTruthy() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "1"]
            )
        )
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "true"]
            )
        )
    }

    func testDisableEnvironmentVariableDoesNotDisableAdoptionWhenFalsey() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "0"]
            )
        )
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "false"]
            )
        )
    }

    func testLegacyLaunchArgumentStillAllowsAdoption() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [FullEmailWebViewAdoptionPolicy.launchArgument],
                environment: [:]
            )
        )
    }

    func testLegacyEnvironmentVariableStillAllowsAdoption() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.environmentKey: "1"]
            )
        )
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.environmentKey: "true"]
            )
        )
    }

    func testDisableLaunchArgumentWinsOverLegacyEnableLaunchArgument() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [
                    FullEmailWebViewAdoptionPolicy.launchArgument,
                    FullEmailWebViewAdoptionPolicy.disableLaunchArgument
                ],
                environment: [:]
            )
        )
    }

    func testDisableEnvironmentVariableWinsOverLegacyEnableEnvironmentVariable() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [
                    FullEmailWebViewAdoptionPolicy.environmentKey: "1",
                    FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "1"
                ]
            )
        )
    }
}

private final class NoopHTMLContentRecoveryService: HTMLContentRecovering, @unchecked Sendable {
    func recoverHTMLContent(messageId: String) async -> String? {
        nil
    }
}

final class FullEmailWebViewPreRenderKeyTests: XCTestCase {
    private func makeKey(
        messageId: String = "m1",
        sourceSignature: String = "sha256:source",
        html: String = "<html>body</html>",
        cid: String = "cid:none",
        width: CGFloat = 390
    ) -> FullEmailWebViewPreRenderKey {
        FullEmailWebViewPreRenderKey.make(
            messageId: messageId,
            sourceSignature: sourceSignature,
            wrappedHTML: html,
            cidAvailabilityFingerprint: cid,
            width: width
        )
    }

    func testIdenticalInputsProduceEqualKeys() {
        XCTAssertEqual(makeKey(), makeKey())
    }

    func testDifferentHTMLProducesDifferentKey() {
        XCTAssertNotEqual(makeKey(html: "<html>a</html>"), makeKey(html: "<html>b</html>"))
    }

    func testDifferentMessageIdProducesDifferentKey() {
        XCTAssertNotEqual(makeKey(messageId: "m1"), makeKey(messageId: "m2"))
    }

    func testDifferentSourceSignatureProducesDifferentKey() {
        XCTAssertNotEqual(
            makeKey(sourceSignature: "sha256:first"),
            makeKey(sourceSignature: "sha256:second")
        )
    }

    func testDifferentCIDAvailabilityProducesDifferentKey() {
        XCTAssertNotEqual(makeKey(cid: "cid:none"), makeKey(cid: "cid:available"))
    }

    func testWidthIsBucketedToNearestPoint() {
        // Sub-point jitter collapses to the same bucket.
        XCTAssertEqual(makeKey(width: 390.2), makeKey(width: 390.4))
        // A full-point difference is a different bucket (would re-layout if adopted).
        XCTAssertNotEqual(makeKey(width: 390), makeKey(width: 391))
    }

    func testHTMLFingerprintIncludesLengthGuardingAgainstCollisions() {
        // Same prefix, different length must not collide.
        XCTAssertNotEqual(makeKey(html: "abc"), makeKey(html: "abcd"))
    }
}

final class FullEmailOpenPayloadReuseValidatorTests: XCTestCase {
    private func makeKey(
        sourceSignature: String = "sha256:source",
        html: String = "<html>body</html>",
        cid: String = "cid:none",
        width: CGFloat = 390
    ) -> FullEmailWebViewPreRenderKey {
        FullEmailWebViewPreRenderKey.make(
            messageId: "message-1",
            sourceSignature: sourceSignature,
            wrappedHTML: html,
            cidAvailabilityFingerprint: cid,
            width: width
        )
    }

    private func makePayload(
        sourceSignature: String = "sha256:source",
        html: String = "<html>body</html>"
    ) -> FullEmailOpenPayload {
        FullEmailOpenPayload(
            messageId: "message-1",
            sourceSignature: sourceSignature,
            html: html,
            presentation: .html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            checkoutAvailability: .ready
        )
    }

    private func makeRequest(
        bodyStorageURI: String? = nil,
        bodyText: String? = "Body",
        senderEmail: String? = "sender@example.com",
        subject: String? = "Subject"
    ) -> OriginalEmailWarmRequest {
        OriginalEmailWarmRequest(
            messageId: "message-1",
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    func testSameHTMLSourceWidthAndCIDAvailabilityIsReusable() {
        let key = makeKey()
        let request = makeRequest()
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: key,
                expectedKey: key,
                entryRequest: request,
                currentRequest: request,
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .reusable
        )
    }

    func testChangedBodyStorageURIDoesNotMissReuseWhenSourceAndWrapperInputsMatch() {
        let key = makeKey()
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: key,
                expectedKey: key,
                entryRequest: makeRequest(bodyStorageURI: nil),
                currentRequest: makeRequest(bodyStorageURI: "file:///tmp/message-1.html"),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .reusable
        )
    }

    func testWhitespaceOnlyWrapperInputChangesAreReusable() {
        let key = makeKey()
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: key,
                expectedKey: key,
                entryRequest: makeRequest(senderEmail: " sender@example.com ", subject: " Subject "),
                currentRequest: makeRequest(senderEmail: "sender@example.com", subject: "Subject"),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .reusable
        )
    }

    func testCanonicalEquivalentBodyTextChangesAreReusable() {
        let key = makeKey()
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: key,
                expectedKey: key,
                entryRequest: makeRequest(bodyText: "Hello&nbsp;=26&nbsp;team=3Cok=3E\n\n\nThanks"),
                currentRequest: makeRequest(bodyText: "Hello & team<ok>\n\nThanks"),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .reusable
        )
    }

    func testChangedSourceSignatureMissesReuse() {
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: makeKey(),
                expectedKey: makeKey(),
                entryRequest: makeRequest(),
                currentRequest: makeRequest(),
                payload: makePayload(),
                currentSourceSignature: "sha256:new-source"
            ),
            .staleSource(currentSourceSignature: "sha256:new-source")
        )
    }

    func testMissingCurrentHTMLSourceMissesReuse() {
        let key = makeKey()
        let request = makeRequest()
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: key,
                expectedKey: key,
                entryRequest: request,
                currentRequest: request,
                payload: makePayload(),
                currentSourceSignature: nil
            ),
            .missingCurrentHTMLSource
        )
    }

    func testChangedHTMLMissesReuse() {
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: makeKey(html: "<html>old</html>"),
                expectedKey: makeKey(html: "<html>new</html>"),
                entryRequest: makeRequest(),
                currentRequest: makeRequest(),
                payload: makePayload(html: "<html>old</html>"),
                currentSourceSignature: "sha256:source"
            ),
            .keyMismatch
        )
    }

    func testChangedCIDAvailabilityMissesReuse() {
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: makeKey(cid: "cid:none"),
                expectedKey: makeKey(cid: "cid:image=available"),
                entryRequest: makeRequest(),
                currentRequest: makeRequest(),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .keyMismatch
        )
    }

    func testChangedWidthMissesReuse() {
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: makeKey(width: 390),
                expectedKey: makeKey(width: 393),
                entryRequest: makeRequest(),
                currentRequest: makeRequest(),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .keyMismatch
        )
    }

    func testChangedBodyTextMissesReuse() {
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: makeKey(),
                expectedKey: makeKey(),
                entryRequest: makeRequest(bodyText: "Old body"),
                currentRequest: makeRequest(bodyText: "New body"),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .wrapperInputsMismatch
        )
    }

    func testChangedWrapperInputsMissReuse() {
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: makeKey(),
                expectedKey: makeKey(),
                entryRequest: makeRequest(subject: "Old subject"),
                currentRequest: makeRequest(subject: "New subject"),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .wrapperInputsMismatch
        )
    }
}

final class FullInteractiveEmailWebViewNavigationDecisionTests: XCTestCase {
    private func decide(_ type: WKNavigationType, _ urlString: String?) -> FullInteractiveEmailWebView.NavigationDecision {
        FullInteractiveEmailWebView.navigationDecision(
            navigationType: type,
            url: urlString.flatMap(URL.init(string:))
        )
    }

    func testInitialAndReloadNavigationsAreAllowed() {
        XCTAssertEqual(decide(.other, "about:blank"), .allow)
        XCTAssertEqual(decide(.other, "https://example.com"), .allow)
        XCTAssertEqual(decide(.reload, "https://example.com"), .allow)
    }

    func testLinkActivationToPublicURLOpensExternally() {
        let url = URL(string: "https://example.com/path")!
        XCTAssertEqual(decide(.linkActivated, "https://example.com/path"), .openExternally(url))
    }

    func testLinkActivationToBlankURLIsCancelled() {
        XCTAssertEqual(decide(.linkActivated, "about:blank"), .cancel)
    }

    func testLinkActivationWithUnparseableURLFallsThroughToAllow() {
        // An empty string is not a parseable URL, so `request.url` is nil — matching the pre-refactor
        // coordinator, which allowed navigations whose URL was nil.
        XCTAssertEqual(decide(.linkActivated, ""), .allow)
    }

    func testUnsupportedSchemesAreCancelled() {
        XCTAssertEqual(decide(.linkActivated, "javascript:alert(1)"), .cancel)
        XCTAssertEqual(decide(.linkActivated, "vbscript:foo"), .cancel)
        XCTAssertEqual(decide(.linkActivated, "file:///etc/passwd"), .cancel)
    }

    func testDataDetectorLinksAreAllowed() {
        XCTAssertEqual(decide(.linkActivated, "x-apple-data-detectors://1"), .allow)
    }

    func testPrivateOrReservedLinksAreBlocked() {
        // Loopback / private hosts must never open from email content. They resolve to a distinct
        // `blockedPrivateNetwork` decision (carrying the URL) so the live coordinator can log the
        // block; the warm delegate treats it as a plain cancel.
        let loopback = URL(string: "http://127.0.0.1/admin")!
        let privateHost = URL(string: "http://192.168.0.1/")!
        XCTAssertEqual(decide(.linkActivated, "http://127.0.0.1/admin"), .blockedPrivateNetwork(loopback))
        XCTAssertEqual(decide(.linkActivated, "http://192.168.0.1/"), .blockedPrivateNetwork(privateHost))
    }

    func testNonLinkNavigationsFallThroughToAllow() {
        // e.g. form submissions to a normal URL are allowed (matches pre-refactor behavior).
        XCTAssertEqual(decide(.formSubmitted, "https://example.com/submit"), .allow)
    }
}
