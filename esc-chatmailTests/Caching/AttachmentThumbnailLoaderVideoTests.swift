import XCTest
@testable import esc_chatmail

/// Pins the loader-side interleavings the video attachment card depends on:
/// a completion arriving after cancel() must not write the image, reset()
/// must permit a fresh load despite the image/isLoading re-entry guard, and
/// a second load while one is in flight must not start a second generation.
@MainActor
final class AttachmentThumbnailLoaderVideoTests: XCTestCase {

    /// Holds the injected video-frame operation open until released. Lock-
    /// guarded because the operation closure runs off the MainActor.
    private final class OperationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _startCount = 0
        private var continuations: [CheckedContinuation<UIImage?, Never>] = []

        var startCount: Int { lock.withLock { _startCount } }

        func run() async -> UIImage? {
            lock.withLock { _startCount += 1 }
            return await withCheckedContinuation { continuation in
                lock.withLock { continuations.append(continuation) }
            }
        }

        func release(with image: UIImage?) {
            let pending: [CheckedContinuation<UIImage?, Never>] = lock.withLock {
                let value = continuations
                continuations.removeAll()
                return value
            }
            pending.forEach { $0.resume(returning: image) }
        }
    }

    private static let attachmentId = "local_video-loader-test"
    private static let localPath = "Attachments/video-loader-test.mov"
    private static let targetSize = CGSize(width: 100, height: 60)

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func makeLoader(gate: OperationGate) -> AttachmentThumbnailLoader {
        AttachmentThumbnailLoader(
            loadVideoThumbnailOperation: { _, _, _, _ in
                await gate.run()
            }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    // Revert-check: fails if loadVideoThumbnail's completion drops its
    // `guard !Task.isCancelled` — a frame delivered after cancel() would then
    // overwrite state the next appearance relies on, and isLoading would
    // flip false under the cancelled request's control.
    func testCompletionAfterCancelDoesNotWriteImage() async {
        let gate = OperationGate()
        let loader = makeLoader(gate: gate)

        loader.loadVideoThumbnail(
            attachmentId: Self.attachmentId,
            localPath: Self.localPath,
            targetSize: Self.targetSize
        )
        await waitUntil { gate.startCount == 1 }
        XCTAssertTrue(loader.isLoading)

        loader.cancel()
        XCTAssertFalse(loader.isLoading)

        gate.release(with: makeImage())
        // Give the (cancelled) task a chance to run its completion.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(loader.image, "A cancelled load must not deliver its frame")
        XCTAssertFalse(loader.isLoading)
    }

    // Revert-check: fails (on the direct XCTAssertNil below) if reset() stops
    // clearing `image` — the loader would then keep serving the stale frame
    // the video card's onChange(of: attachment.localURL) path exists to
    // discard. (cancel() dropping its isLoading clear is caught by the
    // previous test's isLoading asserts, not this one; and prepare(for:)
    // clears image on any request change, so the re-entry guard itself never
    // refuses the reload here.)
    func testResetThenLoadStartsFreshGeneration() async {
        let gate = OperationGate()
        let loader = makeLoader(gate: gate)

        loader.loadVideoThumbnail(
            attachmentId: Self.attachmentId,
            localPath: Self.localPath,
            targetSize: Self.targetSize
        )
        await waitUntil { gate.startCount == 1 }
        gate.release(with: makeImage())
        await waitUntil { loader.image != nil }

        loader.reset()
        XCTAssertNil(loader.image)

        loader.loadVideoThumbnail(
            attachmentId: Self.attachmentId,
            localPath: Self.localPath,
            targetSize: Self.targetSize
        )
        await waitUntil { gate.startCount == 2 }
        gate.release(with: makeImage())
        await waitUntil { loader.image != nil }
    }

    // Revert-check: fails if loadVideoThumbnail loses its
    // `image == nil, !isLoading` re-entry guard (with an unchanged request) —
    // every onAppear during an in-flight extraction would then start another
    // generation, the duplicated-work churn the loader exists to prevent.
    func testSecondLoadWhileInFlightDoesNotStartSecondGeneration() async {
        let gate = OperationGate()
        let loader = makeLoader(gate: gate)

        loader.loadVideoThumbnail(
            attachmentId: Self.attachmentId,
            localPath: Self.localPath,
            targetSize: Self.targetSize
        )
        await waitUntil { gate.startCount == 1 }

        loader.loadVideoThumbnail(
            attachmentId: Self.attachmentId,
            localPath: Self.localPath,
            targetSize: Self.targetSize
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            gate.startCount,
            1,
            "An identical in-flight request must not start a second generation"
        )

        gate.release(with: makeImage())
        await waitUntil { loader.image != nil }
    }
}
