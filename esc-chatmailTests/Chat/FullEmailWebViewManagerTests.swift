import WebKit
import XCTest
@testable import esc_chatmail

private func withEnvironmentValue(
    _ value: String?,
    for key: String,
    run body: () throws -> Void
) rethrows {
    let previousValue = getenv(key).map { String(cString: $0) }
    if let value {
        _ = setenv(key, value, 1)
    } else {
        _ = unsetenv(key)
    }
    defer {
        if let previousValue {
            _ = setenv(key, previousValue, 1)
        } else {
            _ = unsetenv(key)
        }
    }
    try body()
}

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
        html: String = "<html>body</html>"
    ) -> FullEmailPreparedArtifactKey {
        FullEmailPreparedArtifactKey.make(
            messageId: messageId,
            sourceSignature: sourceSignature,
            wrappedHTML: html
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
    func testWarmWithDefaultDisabledAdoptionStoresPayloadWithoutWebViewEntry() async throws {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [:]
            )
        )

        let messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerTests-\(UUID().uuidString)"
        )
        let contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        defer {
            try? FileManager.default.removeItem(at: messagesDirectory)
        }

        let messageId = "payload-only-default-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(simpleHTML(title: "Default disabled"), for: messageId)

        let manager = FullEmailWebViewManager(loader: makeLoader(contentHandler: contentHandler))
        let request = makeRequest(messageId: messageId)

        await manager.warm(request: request, message: nil, width: nil)

        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId))
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
        XCTAssertFalse(manager.isWarmedForTesting(messageId: messageId))

        let prepared = try XCTUnwrap(
            manager.preparedOpenArtifact(
                request: request,
                message: nil,
                width: 390
            )
        )
        XCTAssertEqual(prepared.checkoutAvailability, .warming)
        XCTAssertEqual(prepared.artifact.messageID, messageId)
        let widerPrepared = try XCTUnwrap(
            manager.preparedOpenArtifact(
                request: request,
                message: nil,
                width: 700
            )
        )
        XCTAssertEqual(widerPrepared.artifact.renderSignature, prepared.artifact.renderSignature)
        guard case .html(let preparedHTML) = prepared.artifact.body else {
            return XCTFail("Expected prepared HTML artifact")
        }

        XCTAssertNil(
            manager.checkout(
                messageId: messageId,
                sourceSignature: prepared.artifact.sourceSignature,
                wrappedHTML: preparedHTML,
                message: nil,
                width: 390
            )
        )

        manager.clear()
    }

    func testPrepaintAfterExplicitOpenDoesNotCreateWebViewEntryByDefault() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [:]
            )
        )

        let testStack = TestCoreDataStack()
        let messageId = "explicit-open-prepaint-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withSubject("Subject")
            .withSender(email: "sender@example.com", name: "Sender")
            .withBody("Body \(messageId)")
            .build(in: testStack.viewContext)
        let request = makeRequest(messageId: messageId)
        let artifact = makeArtifact(message: message, html: simpleHTML(title: "Explicit prepaint"))
        let manager = FullEmailWebViewManager()
        defer { manager.clear() }

        manager.prepaintAfterExplicitOpen(
            request: request,
            message: message,
            artifact: artifact,
            width: 390
        )

        XCTAssertFalse(manager.hasPreparedPayloadForTesting(messageId: messageId))
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
    }

    func testPrepaintAfterExplicitOpenCreatesWebViewEntryWhenAdoptionEnabled() {
        withEnvironmentValue("1", for: FullEmailWebViewAdoptionPolicy.enableEnvironmentKey) {
            withEnvironmentValue(nil, for: FullEmailWebViewAdoptionPolicy.disableEnvironmentKey) {
                let testStack = TestCoreDataStack()
                let messageId = "explicit-open-enabled-\(UUID().uuidString)"
                let message = MessageBuilder()
                    .withId(messageId)
                    .withSubject("Subject")
                    .withSender(email: "sender@example.com", name: "Sender")
                    .withBody("Body \(messageId)")
                    .build(in: testStack.viewContext)
                let request = makeRequest(messageId: messageId)
                let artifact = makeArtifact(message: message, html: simpleHTML(title: "Explicit prepaint"))
                let manager = FullEmailWebViewManager()
                defer { manager.clear() }

                manager.prepaintAfterExplicitOpen(
                    request: request,
                    message: message,
                    artifact: artifact,
                    width: 390
                )

                XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId))
                XCTAssertTrue(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
            }
        }
    }

    func testPrepaintAfterExplicitOpenDoesNotCreateWebViewEntryWhenAdoptionExplicitlyDisabled() {
        withEnvironmentValue("1", for: FullEmailWebViewAdoptionPolicy.disableEnvironmentKey) {
            XCTAssertTrue(FullEmailWebViewAdoptionPolicy.explicitlyDisablesPrerenderedWebViewAdoption)

            let testStack = TestCoreDataStack()
            let messageId = "explicit-open-disabled-\(UUID().uuidString)"
            let message = MessageBuilder()
                .withId(messageId)
                .withSubject("Subject")
                .withSender(email: "sender@example.com", name: "Sender")
                .withBody("Body \(messageId)")
                .build(in: testStack.viewContext)
            let request = makeRequest(messageId: messageId)
            let artifact = makeArtifact(message: message, html: simpleHTML(title: "Explicit prepaint"))
            let manager = FullEmailWebViewManager()
            defer { manager.clear() }

            manager.prepaintAfterExplicitOpen(
                request: request,
                message: message,
                artifact: artifact,
                width: 390
            )

            XCTAssertFalse(manager.hasPreparedPayloadForTesting(messageId: messageId))
            XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
        }
    }

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

    private func makeArtifact(message: Message, html: String) -> EmailReaderArtifact {
        EmailReaderArtifact(
            messageID: message.id,
            sourceSignature: "sha256:\(message.id)",
            body: .html(html),
            metadata: EmailMetadataSnapshot(message: message),
            inlineAttachmentAvailabilitySignature: InlineCIDAttachmentAvailabilityFingerprint.make(
                html: html,
                message: message
            ),
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            producedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

final class FullEmailWebViewAdoptionPolicyTests: XCTestCase {
    func testRenderingConfigurationEnablesPreparedHTMLWarmupByDefault() {
        XCTAssertTrue(EmailReaderRenderingConfiguration.enablesPreparedHTMLWarmup)
    }

    func testRenderingConfigurationDisablesOffscreenWebViewAdoptionByDefault() {
        withEnvironmentValue(nil, for: FullEmailWebViewAdoptionPolicy.enableEnvironmentKey) {
            withEnvironmentValue(nil, for: FullEmailWebViewAdoptionPolicy.disableEnvironmentKey) {
                XCTAssertFalse(
                    FullEmailWebViewAdoptionPolicy.isEnabled(
                        arguments: [],
                        environment: [:]
                    )
                )
                XCTAssertFalse(EmailReaderRenderingConfiguration.enablesOffscreenWebViewAdoption)
            }
        }
    }

    func testRenderingConfigurationEnablesOffscreenWebViewAdoptionWhenExplicitlyEnabled() {
        withEnvironmentValue("1", for: FullEmailWebViewAdoptionPolicy.enableEnvironmentKey) {
            withEnvironmentValue(nil, for: FullEmailWebViewAdoptionPolicy.disableEnvironmentKey) {
                XCTAssertTrue(EmailReaderRenderingConfiguration.enablesOffscreenWebViewAdoption)
            }
        }
    }

    func testRenderingConfigurationDisableOverrideWins() {
        withEnvironmentValue("1", for: FullEmailWebViewAdoptionPolicy.enableEnvironmentKey) {
            withEnvironmentValue("1", for: FullEmailWebViewAdoptionPolicy.disableEnvironmentKey) {
                XCTAssertFalse(EmailReaderRenderingConfiguration.enablesOffscreenWebViewAdoption)
            }
        }
    }

    func testAdoptionIsDisabledByDefault() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [:]
            )
        )
    }

    func testExplicitDisablePredicateIsFalseByDefault() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isExplicitlyDisabled(
                arguments: [],
                environment: [:]
            )
        )
    }

    func testExplicitDisablePredicateDetectsLaunchArgument() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isExplicitlyDisabled(
                arguments: [FullEmailWebViewAdoptionPolicy.disableLaunchArgument],
                environment: [:]
            )
        )
    }

    func testExplicitDisablePredicateDetectsEnvironmentVariable() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isExplicitlyDisabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "1"]
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

    func testDisableEnvironmentVariableOverridesAdoptionWhenSetToOne() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [FullEmailWebViewAdoptionPolicy.enableLaunchArgument],
                environment: [FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "1"]
            )
        )
    }

    func testDisableEnvironmentVariableValuesOtherThanOneDoNotOverrideAdoption() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [FullEmailWebViewAdoptionPolicy.enableLaunchArgument],
                environment: [FullEmailWebViewAdoptionPolicy.disableEnvironmentKey: "true"]
            )
        )
    }

    func testLaunchArgumentEnablesAdoption() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [FullEmailWebViewAdoptionPolicy.enableLaunchArgument],
                environment: [:]
            )
        )
    }

    func testEnvironmentVariableEnablesAdoptionWhenSetToOne() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [FullEmailWebViewAdoptionPolicy.enableEnvironmentKey: "1"]
            )
        )
    }

    func testEnvironmentVariableValuesOtherThanOneDoNotEnableAdoption() {
        for value in ["", "0", "false", "true", "yes", "on", "2"] {
            XCTAssertFalse(
                FullEmailWebViewAdoptionPolicy.isEnabled(
                    arguments: [],
                    environment: [FullEmailWebViewAdoptionPolicy.enableEnvironmentKey: value]
                ),
                "value=\(value)"
            )
        }
    }

    func testCompatibilityAliasesStillEnableAdoption() {
        XCTAssertTrue(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [FullEmailWebViewAdoptionPolicy.launchArgument],
                environment: [FullEmailWebViewAdoptionPolicy.environmentKey: "1"]
            )
        )
    }

    func testDisableLaunchArgumentWinsOverEnableLaunchArgument() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [
                    FullEmailWebViewAdoptionPolicy.enableLaunchArgument,
                    FullEmailWebViewAdoptionPolicy.disableLaunchArgument
                ],
                environment: [:]
            )
        )
    }

    func testDisableEnvironmentVariableWinsOverEnableEnvironmentVariable() {
        XCTAssertFalse(
            FullEmailWebViewAdoptionPolicy.isEnabled(
                arguments: [],
                environment: [
                    FullEmailWebViewAdoptionPolicy.enableEnvironmentKey: "1",
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
        html: String = "<html>body</html>"
    ) -> FullEmailPreparedArtifactKey {
        FullEmailPreparedArtifactKey.make(
            messageId: "message-1",
            sourceSignature: sourceSignature,
            wrappedHTML: html
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

    func testSameHTMLSourceAndWrapperInputsAreReusable() {
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

    func testPreparedReuseIgnoresWidthDependentAdoptionIdentity() {
        XCTAssertEqual(
            FullEmailOpenPayloadReuseValidator.decision(
                entryKey: makeKey(),
                expectedKey: makeKey(),
                entryRequest: makeRequest(),
                currentRequest: makeRequest(),
                payload: makePayload(),
                currentSourceSignature: "sha256:source"
            ),
            .reusable
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
