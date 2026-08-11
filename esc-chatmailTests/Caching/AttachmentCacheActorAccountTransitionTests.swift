import XCTest
import UIKit
@testable import esc_chatmail

final class AttachmentCacheActorAccountTransitionTests: XCTestCase {
    func testReusedAttachmentIDKeepsMessageCachesAndExactRemovalIsolated() async throws {
        let firstData = try XCTUnwrap(Self.imageData(color: .red))
        let secondData = try XCTUnwrap(Self.imageData(color: .blue))
        let firstPath = AttachmentPaths.previewPath(
            messageId: "message-one",
            attachmentId: "shared-id"
        )
        let secondPath = AttachmentPaths.previewPath(
            messageId: "message-two",
            attachmentId: "shared-id"
        )
        let loader = PathAttachmentCacheLoader(
            results: [
                firstPath: firstData,
                secondPath: secondData
            ]
        )
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })

        let first = await cache.loadThumbnail(
            for: "shared-id",
            messageId: "message-one",
            from: firstPath
        )
        let second = await cache.loadThumbnail(
            for: "shared-id",
            messageId: "message-two",
            from: secondPath
        )

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.pngData(), second?.pngData())

        await loader.removeAll()
        await cache.removeFromCache(
            messageId: "message-one",
            attachmentId: "shared-id"
        )

        let removedFirst = await cache.loadThumbnail(
            for: "shared-id",
            messageId: "message-one",
            from: firstPath
        )
        let retainedSecond = await cache.loadThumbnail(
            for: "shared-id",
            messageId: "message-two",
            from: secondPath
        )
        XCTAssertNil(removedFirst)
        XCTAssertEqual(retainedSecond?.pngData(), second?.pngData())

        // A standalone deleted Attachment can lose its message relationship
        // before CacheCoordinator inspects it. Nil-message invalidation must
        // conservatively remove every registered message-scoped variant.
        await cache.removeFromCache(messageId: nil, attachmentId: "shared-id")
        let removedSecond = await cache.loadThumbnail(
            for: "shared-id",
            messageId: "message-two",
            from: secondPath
        )
        XCTAssertNil(removedSecond)
    }

    func testNilMessageInvalidationRemovesEveryLocalInlineMessageIdentity() async throws {
        let imageData = try XCTUnwrap(Self.imageData(color: .red))
        let attachmentID = "local_inline_shared-id"
        let firstMessageID = "local-inline-message-one"
        let secondMessageID = "local-inline-message-two"
        let firstPath = AttachmentPaths.previewPath(
            messageId: firstMessageID,
            attachmentId: attachmentID
        )
        let secondPath = AttachmentPaths.previewPath(
            messageId: secondMessageID,
            attachmentId: attachmentID
        )
        let loader = PathAttachmentCacheLoader(
            results: [
                firstPath: imageData,
                secondPath: imageData
            ]
        )
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })

        let first = await cache.loadThumbnail(
            for: attachmentID,
            messageId: firstMessageID,
            from: firstPath
        )
        let second = await cache.loadThumbnail(
            for: attachmentID,
            messageId: secondMessageID,
            from: secondPath
        )
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        await loader.removeAll()
        await cache.removeFromCache(messageId: nil, attachmentId: attachmentID)

        let removedFirst = await cache.loadThumbnail(
            for: attachmentID,
            messageId: firstMessageID,
            from: firstPath
        )
        let removedSecond = await cache.loadThumbnail(
            for: attachmentID,
            messageId: secondMessageID,
            from: secondPath
        )
        XCTAssertNil(removedFirst)
        XCTAssertNil(removedSecond)
    }

    func testAccountTransitionRejectsInFlightThumbnailAndPreventsStaleRepopulation() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.transparentGIF))
        let loader = SuspendedAttachmentCacheLoader(result: imageData)
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })

        let oldLoad = Task {
            await cache.loadThumbnail(for: "local_shared-id", from: "old-account-preview")
        }
        await loader.waitUntilStarted()

        await cache.closeAdmission()
        await cache.clearCache(level: .aggressive)
        let blockedLoad = await cache.loadThumbnail(
            for: "local_blocked-id",
            from: "old-account-preview"
        )
        XCTAssertNil(blockedLoad)

        await loader.release()
        let oldResult = await oldLoad.value
        XCTAssertNil(oldResult, "A cache load invalidated by teardown must not return old-account bytes")

        await cache.reopenAdmission()
        await loader.setResult(nil)
        let postTransitionResult = await cache.loadThumbnail(
            for: "local_shared-id",
            from: "new-account-preview"
        )
        XCTAssertNil(
            postTransitionResult,
            "The in-flight old generation must not repopulate the new account's cache key"
        )
    }

    /// Revert-check: fails if `handleMemoryWarning()` goes back to retiring the account
    /// generation (i.e. if `clearCache(level:)` bumps `accountGeneration` again, or if
    /// `handleMemoryWarning()` is repointed at `clearForAccountTransition()`). Ordinary
    /// memory pressure must not invalidate a decode that is already in flight.
    func testMemoryWarningDoesNotDiscardInFlightThumbnailDecode() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.transparentGIF))
        let loader = SuspendedAttachmentCacheLoader(result: imageData)
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })

        let inFlightLoad = Task {
            await cache.loadThumbnail(for: "local_memory-warning-id", from: "preview-path")
        }
        await loader.waitUntilStarted()

        // No account transition here: no closeAdmission(), no clearForAccountTransition().
        await cache.handleMemoryWarning()

        await loader.release()
        let inFlightResult = await inFlightLoad.value
        XCTAssertNotNil(
            inFlightResult,
            "Memory pressure must not invalidate a thumbnail decode that was already in flight"
        )

        // The loader can no longer produce bytes, so a non-nil result can only come from
        // the memory cache. This fails if the post-store generation guard evicted the
        // entry that the in-flight load just decoded.
        await loader.setResult(nil)
        let cachedResult = await cache.loadThumbnail(for: "local_memory-warning-id", from: "preview-path")
        XCTAssertNotNil(
            cachedResult,
            "The freshly decoded thumbnail must survive a memory warning in the live generation"
        )
    }

    func testMemoryWarningRestoresIdentityForInFlightCompositeThumbnail() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.transparentGIF))
        let loader = SuspendedAttachmentCacheLoader(result: imageData)
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })
        let attachmentID = "remote-in-flight-memory-warning"
        let messageID = "message-in-flight-memory-warning"
        let path = AttachmentPaths.previewPath(
            messageId: messageID,
            attachmentId: attachmentID
        )

        let inFlightLoad = Task {
            await cache.loadThumbnail(
                for: attachmentID,
                messageId: messageID,
                from: path
            )
        }
        await loader.waitUntilStarted()

        await cache.handleMemoryWarning()
        await loader.release()
        let inFlightResult = await inFlightLoad.value
        XCTAssertNotNil(inFlightResult)

        await loader.setResult(nil)
        await cache.removeFromCache(messageId: nil, attachmentId: attachmentID)
        let reloaded = await cache.loadThumbnail(
            for: attachmentID,
            messageId: messageID,
            from: path
        )
        XCTAssertNil(
            reloaded,
            "ID-wide invalidation must find a composite entry restored after memory pressure"
        )
    }

    /// Revert-check: fails if `clearForAccountTransition()` stops bumping `accountGeneration`
    /// (e.g. if it is reduced to a bare `clearCache(level: .aggressive)`, or if
    /// FreshInstallHandler's clear path stops retiring the epoch). This is the account-switch
    /// path that runs *without* `closeAdmission()`.
    func testClearForAccountTransitionInvalidatesInFlightThumbnailLoad() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.transparentGIF))
        let loader = SuspendedAttachmentCacheLoader(result: imageData)
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })

        let oldLoad = Task {
            await cache.loadThumbnail(for: "local_shared-id", from: "old-account-preview")
        }
        await loader.waitUntilStarted()

        // FreshInstallHandler.clearCaches path: retire the epoch without closing admission.
        await cache.clearForAccountTransition()

        await loader.release()
        let oldResult = await oldLoad.value
        XCTAssertNil(
            oldResult,
            "An account transition must invalidate an in-flight load of the old account's bytes"
        )

        // The loader is now empty, so a non-nil result could only come from the retired
        // generation having repopulated the live cache key.
        await loader.setResult(nil)
        let postTransitionResult = await cache.loadThumbnail(
            for: "local_shared-id",
            from: "old-account-preview"
        )
        XCTAssertNil(
            postTransitionResult,
            "The retired generation must not repopulate the new account's cache key"
        )
    }

    func testLegacyRemoteThumbnailPathIsRejectedBeforeLoadingOrCaching() async throws {
        let imageData = try XCTUnwrap(Self.imageData(color: .red))
        let attachmentID = "remote-thumbnail"
        let messageID = "message-thumbnail"
        let legacyPath = AttachmentPaths.previewPath(idOrUUID: attachmentID)
        let currentPath = AttachmentPaths.previewPath(
            messageId: messageID,
            attachmentId: attachmentID
        )
        let loader = PathAttachmentCacheLoader(
            results: [legacyPath: imageData, currentPath: imageData]
        )
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })

        let legacy = await cache.loadThumbnail(
            for: attachmentID,
            messageId: messageID,
            from: legacyPath
        )
        XCTAssertNil(legacy)
        let pathsAfterLegacyLoad = await loader.loadedPaths()
        XCTAssertEqual(pathsAfterLegacyLoad, [])

        let current = await cache.loadThumbnail(
            for: attachmentID,
            messageId: messageID,
            from: currentPath
        )
        XCTAssertNotNil(current)
        let pathsAfterCurrentLoad = await loader.loadedPaths()
        XCTAssertEqual(pathsAfterCurrentLoad, [currentPath])
    }

    func testCurrentRemoteThumbnailPathChangeDoesNotReturnPriorCachedImage() async throws {
        let firstData = try XCTUnwrap(Self.imageData(color: .red))
        let secondData = try XCTUnwrap(Self.imageData(color: .blue))
        let attachmentID = "remote-path-change"
        let messageID = "message-path-change"
        let firstPath = AttachmentPaths.previewPath(
            messageId: messageID,
            attachmentId: attachmentID,
            ext: "jpg"
        )
        let secondPath = AttachmentPaths.previewPath(
            messageId: messageID,
            attachmentId: attachmentID,
            ext: "png"
        )
        let loader = PathAttachmentCacheLoader(
            results: [firstPath: firstData, secondPath: secondData]
        )
        let cache = AttachmentCacheActor(loadAttachmentData: { path in
            await loader.load(path)
        })

        let first = await cache.loadThumbnail(
            for: attachmentID,
            messageId: messageID,
            from: firstPath
        )
        let second = await cache.loadThumbnail(
            for: attachmentID,
            messageId: messageID,
            from: secondPath
        )

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.pngData(), second?.pngData())
    }

    private static let transparentGIF =
        "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    private static func imageData(color: UIColor) -> Data? {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 2, height: 2)))
        }.pngData()
    }
}

private actor PathAttachmentCacheLoader {
    private var results: [String: Data]
    private var paths: [String] = []

    init(results: [String: Data]) {
        self.results = results
    }

    func load(_ path: String?) -> Data? {
        guard let path else { return nil }
        paths.append(path)
        return results[path]
    }

    func loadedPaths() -> [String] {
        paths
    }

    func removeAll() {
        results.removeAll()
    }
}

private actor SuspendedAttachmentCacheLoader {
    private var result: Data?
    private var isSuspended = true
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: Data?) {
        self.result = result
    }

    func load(_ path: String?) async -> Data? {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if isSuspended {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return result
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isSuspended = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func setResult(_ result: Data?) {
        self.result = result
    }
}
