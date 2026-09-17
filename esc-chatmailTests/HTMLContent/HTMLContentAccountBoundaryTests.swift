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
        defer {
            try? handler.reopenAccountWork()
            try? FileManager.default.removeItem(at: directory)
        }

        let oldHTMLGeneration = try XCTUnwrap(handler.captureAccountGeneration())
        let capturedInvalidationContext = await loader.captureInvalidationAccountContext(
            expectedAccountGeneration: oldHTMLGeneration
        )
        let oldInvalidationContext = try XCTUnwrap(capturedInvalidationContext)

        handler.closeAccountWork()
        try await handler.deleteAllHTMLFromClosedAccount()
        await loader.closeAccountWorkAndClearCaches()
        try handler.reopenAccountWork()
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

        // The loader's close/reopen above also cycles RenderedMessageCache.shared,
        // so this entry belongs to the reopened account.
        let bubbleVariant = RenderedMessageVariantKey(MessageBubbleContentSource.chatBubblePreviewMode)
        let bubbleSourceSignature = "new-source-\(UUID().uuidString)"
        await RenderedMessageCache.shared.storeChatBubbleText(
            RenderedMessageChatBubbleText(plainText: "new account", hasRichContent: true),
            messageId: messageId,
            sourceSignature: bubbleSourceSignature,
            variantKey: bubbleVariant
        )
        await loader.invalidateContent(
            messageId: messageId,
            accountContext: oldInvalidationContext
        )

        XCTAssertGreaterThan(loader.debugCachedVariantCount(for: messageId), 0)
        // Revert-check: stale-context rejection in
        // `HTMLContentLoader.invalidateContent(messageId:accountContext:)`.
        // HONEST SCOPE: rejection is layered — the up-front generation guards,
        // then `expectedAccountGeneration:` on the RenderedMessageCache eviction —
        // so this assertion fails only when both layers are removed.
        let freshBubble = await RenderedMessageCache.shared.cachedChatBubbleText(
            messageId: messageId,
            sourceSignature: bubbleSourceSignature,
            variantKey: bubbleVariant
        )
        XCTAssertEqual(freshBubble?.plainText, "new account")

        await RenderedMessageCache.shared.invalidate(
            messageId: messageId,
            sourceSignature: bubbleSourceSignature
        )
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
