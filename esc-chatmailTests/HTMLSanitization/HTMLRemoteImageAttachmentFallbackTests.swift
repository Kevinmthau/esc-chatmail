import XCTest
@testable import esc_chatmail

final class HTMLRemoteImageAttachmentFallbackTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII=")!

    func testInlineAttachmentStyleImages_rewritesSalesforceStyleAttachmentImage() async throws {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let headers: [String: String] = [
                "Content-Type": "image/png",
                "Content-Disposition": "attachment; filename=\"Brambles_Banner.png\"",
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

        let html = """
        <html><body><img src="https://d3t000000dywoeaq.file.force.com/file-asset-public/Brambles_Banner?oid=00D3t000000dywO"></body></html>
        """

        let result = await service.inlineAttachmentStyleImages(
            in: html,
            senderEmail: "thomas@brambles.golf"
        )

        XCTAssertTrue(result.contains("src=\"data:image/"))
        XCTAssertFalse(result.contains("https://d3t000000dywoeaq.file.force.com/file-asset-public/Brambles_Banner?oid=00D3t000000dywO"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
        XCTAssertEqual(snapshot.referers, ["https://brambles.golf/", "https://brambles.golf/"])
    }

    func testPreviewInlineAttachmentStyleImages_eagerlyRewritesSalesforceStyleAttachmentImage() async throws {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let headers: [String: String] = [
                "Content-Type": "image/png",
                "Content-Disposition": "attachment; filename=\"Brambles_Banner.png\"",
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

        let html = """
        <html><body><img src="https://d3t000000dywoeaq.file.force.com/file-asset-public/Brambles_Banner?oid=00D3t000000dywO"></body></html>
        """

        let result = await service.previewInlineAttachmentStyleImages(
            in: html,
            senderEmail: "thomas@brambles.golf"
        )

        XCTAssertTrue(result.html.contains("src=\"data:image/"))
        XCTAssertFalse(result.html.contains("https://d3t000000dywoeaq.file.force.com/file-asset-public/Brambles_Banner?oid=00D3t000000dywO"))
        XCTAssertFalse(result.hasPendingUpdates)
        XCTAssertFalse(result.needsWarmup)

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
        XCTAssertEqual(snapshot.referers, ["https://brambles.golf/", "https://brambles.golf/"])
    }

    func testPreviewInlineAttachmentStyleImages_boundsEagerSalesforceProbesAcrossDocument() async {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback(
            requestExecutor: { request in
                await recorder.record(request)
                try? await Task.sleep(nanoseconds: 300_000_000)

                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://d3t000000dywoeaq.file.force.com/file-asset-public/Asset")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/png",
                        "Content-Disposition": "attachment; filename=\"asset.png\"",
                        "Content-Length": "\(imageData.count)"
                    ]
                )!

                if request.httpMethod == "HEAD" {
                    return (Data(), response)
                }

                return (imageData, response)
            },
            previewEagerResolutionTimeout: 0.05
        )

        let imageTags = (0..<6)
            .map { index in
                #"<img src="https://d3t000000dywoeaq.file.force.com/file-asset-public/Asset\#(index)?oid=00D3t000000dywO">"#
            }
            .joined()
        let html = "<html><body>\(imageTags)</body></html>"

        let startedAt = Date()
        let result = await service.previewInlineAttachmentStyleImages(
            in: html,
            senderEmail: "thomas@brambles.golf"
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.hasPendingUpdates)
        XCTAssertTrue(result.needsWarmup)
        XCTAssertLessThan(elapsed, 0.25)
    }

    func testPreviewInlineAttachmentStyleImages_keepsGenericDynamicImagesLazy() async {
        let service = HTMLRemoteImageAttachmentFallback { _ in
            XCTFail("Generic dynamic preview image URLs should warm in the background, not block preview rewriting")
            return (
                Data(),
                HTTPURLResponse(url: URL(string: "https://cdn.example.com/open.php")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let html = #"<img src="https://cdn.example.com/open.php?id=hero" alt="hero">"#
        let result = await service.previewInlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.hasPendingUpdates)
        XCTAssertTrue(result.needsWarmup)
    }

    func testInlineAttachmentStyleImages_leavesNormalFileExtensionImagesUntouched() async {
        let service = HTMLRemoteImageAttachmentFallback { _ in
            XCTFail("Normal image URLs should not be probed by the fallback")
            return (
                Data(),
                HTTPURLResponse(url: URL(string: "https://example.com/banner.jpg")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let html = #"<img src="https://example.com/banner.jpg" alt="banner">"#
        let result = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        XCTAssertEqual(result, html)
    }

    func testInlineAttachmentStyleImages_doesNotRewriteInlineResponses() async throws {
        let recorder = RequestRecorder()
        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/png",
                        "Content-Disposition": "inline; filename=\"banner.png\""
                    ]
                )
            )

            return (Data(), response)
        }

        let html = #"<img src="https://cdn.example.com/assets/banner?variant=1">"#
        let result = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        XCTAssertEqual(result, html)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD"])
    }

    func testInlineAttachmentStyleImages_rewritesInlineModernFormatImagesToSafeDataURL() async throws {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/webp",
                        "Content-Disposition": "inline; filename=\"hero.webp\"",
                        "Content-Length": "\(imageData.count)"
                    ]
                )
            )

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        let html = #"<img src="https://cdn.example.com/banner.jpg?format=webp&width=600">"#
        let result = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        XCTAssertTrue(result.contains("src=\"data:image/"))
        XCTAssertFalse(result.contains("format=webp"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
        XCTAssertEqual(snapshot.referers, ["https://example.com/", "https://example.com/"])
        XCTAssertEqual(snapshot.accepts, [
            "image/png,image/jpeg,image/gif,image/bmp,image/*;q=0.8,*/*;q=0.5",
            "image/png,image/jpeg,image/gif,image/bmp,image/*;q=0.8,*/*;q=0.5"
        ])
    }

    func testInlineAttachmentStyleImages_doesNotNegativeCacheTransientFailures() async {
        let recorder = RequestRecorder()
        let attempts = AttemptCounter()
        let imageData = onePixelPNG

        let service = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let requestKey = "\(request.httpMethod ?? "GET")|\(request.url?.absoluteString ?? "")"
            let attempt = await attempts.increment(for: requestKey)
            if request.httpMethod == "HEAD", attempt == 1 {
                throw URLError(.timedOut)
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://cdn.example.com/open.php?id=hero")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/png",
                    "Content-Disposition": "attachment; filename=\"hero.png\"",
                    "Content-Length": "\(imageData.count)"
                ]
            )!

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        let html = #"<img src="https://cdn.example.com/open.php?id=hero">"#

        let first = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")
        XCTAssertEqual(first, html)

        let second = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")
        XCTAssertTrue(second.contains("src=\"data:image/"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "HEAD", "GET"])
    }

    func testInlineAttachmentStyleImages_boundsPositiveDataURLCache() async {
        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback(
            requestExecutor: { request in
                await recorder.record(request)

                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://cdn.example.com/open.php?id=fallback")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/png",
                        "Content-Disposition": "attachment; filename=\"hero.png\"",
                        "Content-Length": "\(imageData.count)"
                    ]
                )!

                if request.httpMethod == "HEAD" {
                    return (Data(), response)
                }

                return (imageData, response)
            },
            rewrittenDataURLCacheMaxEntries: 1,
            rewrittenDataURLCacheMaxBytes: 1024
        )

        let firstHTML = #"<img src="https://cdn.example.com/open.php?id=first">"#
        let secondHTML = #"<img src="https://cdn.example.com/open.php?id=second">"#

        _ = await service.inlineAttachmentStyleImages(in: firstHTML, senderEmail: "sender@example.com")
        _ = await service.inlineAttachmentStyleImages(in: secondHTML, senderEmail: "sender@example.com")
        _ = await service.inlineAttachmentStyleImages(in: firstHTML, senderEmail: "sender@example.com")

        let snapshot = await recorder.snapshot()
        let firstURLRequests = zip(snapshot.urls, snapshot.methods).filter { url, _ in
            url.contains("id=first")
        }.map { $0.1 }

        XCTAssertEqual(firstURLRequests, ["HEAD", "GET", "HEAD", "GET"])
    }

    func testInlineAttachmentStyleImages_returnsWithinBudgetWhenRequestExecutorHangs() async {
        let hungRequestCompleted = RemoteImageFallbackThreadSafeFlag()
        let service = HTMLRemoteImageAttachmentFallback { _ in
            // Only a sleep that runs to completion counts; a cancelled one is not a finished request.
            if (try? await Task.sleep(nanoseconds: 60_000_000_000)) != nil {
                hungRequestCompleted.set()
            }
            throw URLError(.timedOut)
        }

        let html = #"<img src="https://cdn.example.com/open.php?id=hero">"#

        let startedAt = Date()
        let result = await service.inlineAttachmentStyleImages(
            in: html,
            senderEmail: "sender@example.com",
            perURLTimeoutNanoseconds: 500_000_000
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result, html)
        // Ordering proof: the call must come back while the request is still hung. Without the
        // per-URL timeout it returns only after the executor's sleep, which sets the flag first.
        // Revert-check: dropping the `racedResolvedDataURL` branch from
        // `HTMLRemoteImageAttachmentFallback.resolvedDataURL` waits out the 60s sleep and fails both
        // assertions below.
        XCTAssertFalse(hungRequestCompleted.isSet)
        // Loose sanity bound that the 0.5s budget, not some longer timer, governs. It was 2.0s,
        // which left less headroom than the 1.8s of scheduling jitter the parallel-fan-out test
        // below once hit on CI.
        XCTAssertLessThan(elapsed, 10.0)
    }

    func testInlineAttachmentStyleImages_resolvesCandidateURLsInParallel() async {
        // Matches the production per-document candidate cap, so every URL can be in flight at once.
        let expectedFanOut = 6
        let barrier = ConcurrentRequestBarrier()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback { request in
            await barrier.enter()
            await barrier.exit()

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://d3t000000dywoeaq.file.force.com/file-asset-public/Asset")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/png",
                    "Content-Disposition": "attachment; filename=\"asset.png\"",
                    "Content-Length": "\(imageData.count)"
                ]
            )!

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        let imageTags = (0..<expectedFanOut)
            .map { index in
                #"<img src="https://d3t000000dywoeaq.file.force.com/file-asset-public/Asset\#(index)?oid=00D3t000000dywO">"#
            }
            .joined()
        let html = "<html><body>\(imageTags)</body></html>"

        let resolution = Task {
            await service.inlineAttachmentStyleImages(
                in: html,
                senderEmail: "thomas@brambles.golf"
            )
        }

        // Every request parks at the barrier until it is released, so all six HEADs can be in
        // flight together only if the candidates fan out concurrently. This used to assert a
        // wall-clock budget over 400ms sleeps (sequential ~4.8s vs parallel ~0.8s), which flaked
        // at 2.57s against a 2.5s bound on a loaded CI runner.
        // Revert-check: serialising `HTMLRemoteImageAttachmentFallback.resolveCandidateDataURLs`
        // (awaiting each `resolvedDataURL` in a plain loop instead of the task group) parks one
        // HEAD at a time, so this wait times out and the observed maximum is 1.
        await waitUntil { await barrier.inFlightCount == expectedFanOut }
        // Released unconditionally so a failed wait still drains instead of hanging the test.
        await barrier.release()

        let result = await resolution.value
        let maxInFlightCount = await barrier.maxInFlightCount

        XCTAssertEqual(maxInFlightCount, expectedFanOut)
        XCTAssertEqual(result.components(separatedBy: "src=\"data:image/").count - 1, expectedFanOut)
    }

    func testInlineAttachmentStyleImages_callerTimeoutDoesNotPoisonCache() async {
        let gate = SlowRequestGate()
        let imageData = onePixelPNG

        let service = HTMLRemoteImageAttachmentFallback { request in
            await gate.waitIfNeeded()

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://cdn.example.com/open.php?id=hero")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/png",
                    "Content-Disposition": "attachment; filename=\"hero.png\"",
                    "Content-Length": "\(imageData.count)"
                ]
            )!

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        let html = #"<img src="https://cdn.example.com/open.php?id=hero">"#

        // First call: tight per-URL budget while the executor is gated — the caller times out and
        // returns the unrewritten HTML. The cached resolution task is still running in the background.
        let timedOut = await service.inlineAttachmentStyleImages(
            in: html,
            senderEmail: "sender@example.com",
            perURLTimeoutNanoseconds: 100_000_000
        )
        XCTAssertEqual(timedOut, html)

        // Release the executor and let the in-flight task drain into the cache.
        await gate.open()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Second call: the URL must still resolve. If the first caller had poisoned the cache by
        // recording a transient failure, this call would return unchanged HTML.
        let resolved = await service.inlineAttachmentStyleImages(
            in: html,
            senderEmail: "sender@example.com"
        )
        XCTAssertTrue(resolved.contains("src=\"data:image/"))
    }

    func testAccountTransitionDrainsOldResolutionAndDoesNotRestoreItsCache() async {
        let gate = AccountTransitionRequestGate()
        let imageData = onePixelPNG
        let service = HTMLRemoteImageAttachmentFallback { request in
            await gate.waitForReleaseIgnoringCancellation()
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://cdn.example.com/open.php?id=old")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/png",
                    "Content-Disposition": "attachment; filename=\"old.png\"",
                    "Content-Length": "\(imageData.count)"
                ]
            )!
            return request.httpMethod == "HEAD" ? (Data(), response) : (imageData, response)
        }
        let html = #"<img src="https://cdn.example.com/open.php?id=old">"#

        let oldResolution = Task {
            await service.inlineAttachmentStyleImages(
                in: html,
                senderEmail: "old@example.com"
            )
        }
        await gate.waitUntilStarted()

        let closeFinished = RemoteImageFallbackThreadSafeFlag()
        let closeTask = Task {
            await service.closeAccountWorkAndAwait()
            closeFinished.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            closeFinished.isSet,
            "Account teardown must drain a cancellation-insensitive old image request"
        )

        await gate.release()
        await closeTask.value
        let oldResolutionHTML = await oldResolution.value
        XCTAssertEqual(oldResolutionHTML, html)

        await service.reopenAccountWork()
        let freshLookup = await service.cachedInlineAttachmentStyleImages(
            in: html,
            senderEmail: "old@example.com"
        )
        XCTAssertEqual(freshLookup.html, html)
        XCTAssertTrue(freshLookup.hasPendingUpdates)
        XCTAssertTrue(freshLookup.needsWarmup)
    }

    private func waitUntil(
        timeout: TimeInterval = 10.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

/// Parks every request until `release()` and records the peak number in flight at once, so a
/// parallelism assertion rests on observed overlap rather than on wall-clock timing.
private actor ConcurrentRequestBarrier {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var inFlightCount = 0
    private(set) var maxInFlightCount = 0

    func enter() async {
        inFlightCount += 1
        maxInFlightCount = max(maxInFlightCount, inFlightCount)
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func exit() {
        inFlightCount -= 1
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor SlowRequestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitIfNeeded() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor AccountTransitionRequestGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForReleaseIgnoringCancellation() async {
        started = true
        let startWaiters = startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }
}

private final class RemoteImageFallbackThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private actor RequestRecorder {
    private(set) var methods: [String] = []
    private(set) var referers: [String?] = []
    private(set) var accepts: [String?] = []
    private(set) var urls: [String] = []

    func record(_ request: URLRequest) {
        methods.append(request.httpMethod ?? "")
        referers.append(request.value(forHTTPHeaderField: "Referer"))
        accepts.append(request.value(forHTTPHeaderField: "Accept"))
        urls.append(request.url?.absoluteString ?? "")
    }

    func snapshot() -> (methods: [String], referers: [String?], accepts: [String?], urls: [String]) {
        (methods, referers, accepts, urls)
    }
}

private actor AttemptCounter {
    private var attempts: [String: Int] = [:]

    func increment(for key: String) -> Int {
        let nextValue = (attempts[key] ?? 0) + 1
        attempts[key] = nextValue
        return nextValue
    }
}
