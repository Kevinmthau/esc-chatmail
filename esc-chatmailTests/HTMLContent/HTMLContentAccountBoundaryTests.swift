import XCTest
@testable import esc_chatmail

final class HTMLContentAccountBoundaryTests: XCTestCase {
    func testStoredHTMLInspectionDetectsLegacyCanonicalFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLContentStoredFiles-\(UUID().uuidString)", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let isInitiallyPopulated = try handler.hasStoredHTMLFiles()
        XCTAssertNotNil(handler.saveHTML("<p>old account</p>", for: "legacy"))
        let hasLegacyHTML = try handler.hasStoredHTMLFiles()

        XCTAssertFalse(isInitiallyPopulated)
        XCTAssertTrue(hasLegacyHTML)
    }

    // HONEST SCOPE: this does NOT fail under a revert of `hasStoredHTMLFiles()`'s
    // do/catch rewrite — the pre-fix `fileExists` guard also let a non-directory's
    // `contentsOfDirectory` error propagate. It pins the rewrite's error taxonomy:
    // only `.fileReadNoSuchFile`/`.fileNoSuchFile` may return false, so widening that
    // catch (or swapping in `try?`) turns an unreadable directory into "no HTML here"
    // and lets `prepareLocalStoreForAuthenticatedAccount` publish over another account.
    func testStoredHTMLInspectionDoesNotTreatEnumerationFailureAsEmpty() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLContentStoredFiles-\(UUID().uuidString)")
        try Data([1]).write(to: path)
        let handler = HTMLContentHandler(messagesDirectory: path)
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertThrowsError(try handler.hasStoredHTMLFiles())
    }

    func testCloseIsSharedAcrossHandlersAndRejectsStaleGenerationAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLContentAccountBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        let firstHandler = HTMLContentHandler(messagesDirectory: directory)
        let secondHandler = HTMLContentHandler(messagesDirectory: directory)
        defer {
            try? secondHandler.reopenAccountWork()
            try? FileManager.default.removeItem(at: directory)
        }

        let oldGeneration = try XCTUnwrap(firstHandler.captureAccountGeneration())
        XCTAssertNotNil(firstHandler.saveHTML("<p>old account</p>", for: "shared"))
        XCTAssertEqual(secondHandler.loadHTML(for: "shared"), "<p>old account</p>")

        secondHandler.closeAccountWork()
        try await secondHandler.deleteAllHTMLFromClosedAccount()

        XCTAssertNil(firstHandler.loadHTML(for: "shared"))
        XCTAssertNil(firstHandler.saveHTML("<p>blocked</p>", for: "blocked"))
        XCTAssertNil(
            firstHandler.saveHTML(
                "<p>stale</p>",
                for: "stale",
                expectedGeneration: oldGeneration
            )
        )

        try secondHandler.reopenAccountWork()
        XCTAssertNil(
            firstHandler.saveHTML(
                "<p>stale after reopen</p>",
                for: "stale",
                expectedGeneration: oldGeneration
            )
        )

        let newGeneration = try XCTUnwrap(firstHandler.captureAccountGeneration())
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertNotNil(
            firstHandler.saveHTML(
                "<p>new account</p>",
                for: "shared",
                expectedGeneration: newGeneration
            )
        )
        XCTAssertEqual(secondHandler.loadHTML(for: "shared"), "<p>new account</p>")
    }

    func testStaleGenerationCannotDeleteReopenedAccountHTML() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLContentStaleDelete-\(UUID().uuidString)", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer {
            try? handler.reopenAccountWork()
            try? FileManager.default.removeItem(at: directory)
        }

        let staleGeneration = try XCTUnwrap(handler.captureAccountGeneration())
        handler.closeAccountWork()
        try await handler.deleteAllHTMLFromClosedAccount()
        try handler.reopenAccountWork()
        XCTAssertNotNil(handler.saveHTML("<p>new account</p>", for: "shared"))

        handler.deleteHTML(
            for: "shared",
            bodyStorageURI: nil,
            expectedGeneration: staleGeneration
        )

        XCTAssertEqual(handler.loadHTML(for: "shared"), "<p>new account</p>")
    }

    @MainActor
    func testClosedAccountDeletionRunsOffMainThreadAfterSynchronousClose() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLContentOffMainDeletion-\(UUID().uuidString)", isDirectory: true)
        let execution = HTMLDeletionExecutionRecorder()
        let handler = HTMLContentHandler(
            messagesDirectory: directory,
            deleteHTMLFiles: { directory in
                execution.record(isMainThread: Thread.isMainThread)
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
                for fileURL in contents {
                    try FileManager.default.removeItem(at: fileURL)
                }
            }
        )
        defer {
            try? handler.reopenAccountWork()
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNotNil(handler.saveHTML("<p>old account</p>", for: "old"))

        handler.closeAccountWork()

        XCTAssertNil(
            handler.saveHTML("<p>must stay blocked</p>", for: "blocked"),
            "Closing must reject new writes before the asynchronous deletion begins"
        )
        try await handler.deleteAllHTMLFromClosedAccount()

        XCTAssertEqual(execution.didRunOnMainThread, false)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("old.html").path
            )
        )
    }

    func testMessageBubbleAnalysisCacheRejectsStaleGenerationAfterReopen() throws {
        let cache = MessageBubbleHTMLAnalysisCache()
        let oldGeneration = try XCTUnwrap(cache.captureAccountGeneration())
        let oldAnalysis = MessageBubbleHTMLAnalysis.placeholder(hasHTMLSource: true)

        cache.setValue(
            oldAnalysis,
            forKey: "old-account",
            expectedGeneration: oldGeneration
        )
        XCTAssertNotNil(
            cache.value(
                forKey: "old-account",
                expectedGeneration: oldGeneration
            )
        )

        cache.closeAccountWorkAndClear()
        cache.reopenAccountWork()
        cache.setValue(
            oldAnalysis,
            forKey: "stale-write",
            expectedGeneration: oldGeneration
        )

        XCTAssertNil(cache.value(forKey: "stale-write"))
        XCTAssertFalse(cache.isAccountGenerationCurrent(oldGeneration))
    }

    func testHTMLContentResultCacheRejectsStaleReadAndWriteAfterReopen() throws {
        let cache = HTMLContentResultCache()
        let oldGeneration = try XCTUnwrap(cache.captureAccountGeneration())
        let oldResult = HTMLLoadResult(
            html: "<p>old account</p>",
            source: .messageId,
            sourceSignature: "old-source"
        )

        cache.store(
            oldResult,
            cacheKey: "shared-cache-key",
            variantKey: "shared-variant",
            messageId: "shared-message",
            cost: 32,
            expectedGeneration: oldGeneration
        )
        XCTAssertEqual(
            cache.resultForVariant(
                "shared-variant",
                expectedGeneration: oldGeneration
            )?.html,
            "<p>old account</p>"
        )

        cache.closeAccountWorkAndClear()
        cache.reopenAccountWork()

        cache.store(
            oldResult,
            cacheKey: "stale-cache-key",
            variantKey: "shared-variant",
            messageId: "shared-message",
            cost: 32,
            expectedGeneration: oldGeneration
        )
        XCTAssertNil(
            cache.resultForVariant(
                "shared-variant",
                expectedGeneration: oldGeneration
            )
        )

        let newGeneration = try XCTUnwrap(cache.captureAccountGeneration())
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertNil(
            cache.resultForVariant(
                "shared-variant",
                expectedGeneration: newGeneration
            )
        )

        let newResult = HTMLLoadResult(
            html: "<p>new account</p>",
            source: .messageId,
            sourceSignature: "new-source"
        )
        cache.store(
            newResult,
            cacheKey: "fresh-cache-key",
            variantKey: "shared-variant",
            messageId: "shared-message",
            cost: 32,
            expectedGeneration: newGeneration
        )
        XCTAssertEqual(
            cache.result(
                forKey: "fresh-cache-key",
                expectedGeneration: newGeneration
            )?.html,
            "<p>new account</p>"
        )
    }

    func testStaleInvalidationContextDoesNotEvictReopenedAccountCaches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLInvalidationBoundary-\(UUID().uuidString)", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: directory)
        let loader = HTMLContentLoader(
            contentHandler: handler,
            recoveryService: AccountBoundaryNoopRecoverer()
        )
        let processedTextCache = ProcessedTextCache()
        defer {
            try? handler.reopenAccountWork()
            try? FileManager.default.removeItem(at: directory)
        }

        let oldHTMLGeneration = try XCTUnwrap(handler.captureAccountGeneration())
        let capturedInvalidationContext = await loader.captureInvalidationAccountContext(
            expectedAccountGeneration: oldHTMLGeneration
        )
        let oldInvalidationContext = try XCTUnwrap(capturedInvalidationContext)
        let capturedProcessedGeneration = await processedTextCache.captureAccountGeneration()
        let oldProcessedGeneration = try XCTUnwrap(capturedProcessedGeneration)

        handler.closeAccountWork()
        try await handler.deleteAllHTMLFromClosedAccount()
        await processedTextCache.closeAccountWorkAndClear()
        await loader.closeAccountWorkAndClearCaches()
        try handler.reopenAccountWork()
        await processedTextCache.reopenAccountWork()
        await loader.reopenAccountWork()

        let messageId = "shared-message"
        XCTAssertNotNil(handler.saveHTML("<html><body>new account</body></html>", for: messageId))
        let freshHTMLGeneration = try XCTUnwrap(handler.captureAccountGeneration())
        let loaded = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            expectedAccountGeneration: freshHTMLGeneration
        )
        XCTAssertNotNil(loaded.html)
        XCTAssertGreaterThan(loader.debugCachedVariantCount(for: messageId), 0)

        let capturedFreshProcessedGeneration = await processedTextCache.captureAccountGeneration()
        let freshProcessedGeneration = try XCTUnwrap(capturedFreshProcessedGeneration)
        await processedTextCache.set(
            messageId: messageId,
            sourceSignature: "new-source",
            previewMode: ProcessedTextCache.chatBubblePreviewMode,
            plainText: "new account",
            hasRichContent: true,
            expectedAccountGeneration: freshProcessedGeneration
        )

        await loader.invalidateContent(
            messageId: messageId,
            accountContext: oldInvalidationContext
        )
        await processedTextCache.invalidate(
            messageId: messageId,
            expectedAccountGeneration: oldProcessedGeneration,
            invalidatesRenderedMessage: false
        )

        XCTAssertGreaterThan(loader.debugCachedVariantCount(for: messageId), 0)
        let freshProcessedEntry = await processedTextCache.get(
            messageId: messageId,
            sourceSignature: "new-source",
            previewMode: ProcessedTextCache.chatBubblePreviewMode,
            expectedAccountGeneration: freshProcessedGeneration
        )
        XCTAssertEqual(freshProcessedEntry?.plainText, "new account")
    }

    // Pins the contract that `HTMLContentRecoveryService.performRecoveryToCompletion`
    // depends on when it passes `invalidatesRenderedMessage: false`: that flag must
    // suppress ProcessedTextCache's own RenderedMessageCache hop, which is UNSCOPED
    // (it calls `RenderedMessageCache.shared.invalidate(messageId:reason:)` with no
    // expected generation) and would therefore reach across an account transition.
    // This test fails if the flag stops being honored — i.e. if the rendered hop is
    // made unconditional again — because the seeded rendered artifact would be evicted.
    // A fresh `ProcessedTextCache()` is used (not `.shared`) so the surrounding
    // close/reopen-sensitive singleton state is untouched, matching
    // `testStaleInvalidationContextDoesNotEvictReopenedAccountCaches` above.
    func testProcessedTextInvalidationWithoutRenderedFlagLeavesRenderedCacheUntouched() async throws {
        let messageId = "processed-text-rendered-flag-\(UUID().uuidString)"
        let sourceSignature = "rendered-flag-source-\(UUID().uuidString)"
        let variantKey: RenderedMessageVariantKey = "processed-text-rendered-flag"
        let processedTextCache = ProcessedTextCache()

        await RenderedMessageCache.shared.storeChatBubbleText(
            RenderedMessageChatBubbleText(plainText: "rendered survives", hasRichContent: false),
            messageId: messageId,
            sourceSignature: sourceSignature,
            variantKey: variantKey
        )
        let seededBubble = await RenderedMessageCache.shared.cachedChatBubbleText(
            messageId: messageId,
            sourceSignature: sourceSignature,
            variantKey: variantKey
        )
        XCTAssertNotNil(seededBubble, "Precondition: the rendered artifact must be cached before invalidation")

        let capturedProcessedGeneration = await processedTextCache.captureAccountGeneration()
        let processedGeneration = try XCTUnwrap(capturedProcessedGeneration)
        await processedTextCache.set(
            messageId: messageId,
            plainText: "processed text",
            hasRichContent: false,
            expectedAccountGeneration: processedGeneration
        )

        await processedTextCache.invalidate(
            messageId: messageId,
            expectedAccountGeneration: processedGeneration,
            invalidatesRenderedMessage: false
        )

        // The invalidation itself must have run — otherwise the rendered entry
        // would survive for the wrong reason (a generation-rejected no-op).
        let invalidatedProcessedEntry = await processedTextCache.get(
            messageId: messageId,
            expectedAccountGeneration: processedGeneration
        )
        XCTAssertNil(invalidatedProcessedEntry)

        let survivingBubble = await RenderedMessageCache.shared.cachedChatBubbleText(
            messageId: messageId,
            sourceSignature: sourceSignature,
            variantKey: variantKey
        )
        XCTAssertEqual(
            survivingBubble?.plainText,
            "rendered survives",
            "invalidatesRenderedMessage: false must suppress ProcessedTextCache's unscoped rendered eviction"
        )

        await RenderedMessageCache.shared.invalidate(messageId: messageId)
    }
}

private struct AccountBoundaryNoopRecoverer: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? { nil }
}

private final class HTMLDeletionExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _didRunOnMainThread: Bool?

    var didRunOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _didRunOnMainThread
    }

    func record(isMainThread: Bool) {
        lock.lock()
        _didRunOnMainThread = isMainThread
        lock.unlock()
    }
}
