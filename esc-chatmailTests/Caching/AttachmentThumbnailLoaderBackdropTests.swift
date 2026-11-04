import UIKit
import XCTest
@testable import esc_chatmail

/// Pins how the loader publishes an image with what it needs behind it: together, so a
/// transparent image never draws for a frame without its card, and never across a request the
/// suspension between the two has outlived.
@MainActor
final class AttachmentThumbnailLoaderBackdropTests: XCTestCase {

    /// Holds the injected backdrop resolution open until released. Lock-guarded because the
    /// operation closure runs off the MainActor.
    private final class BackdropGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _startCount = 0
        private var continuations: [CheckedContinuation<ImageBackdropPolicy, Never>] = []

        var startCount: Int { lock.withLock { _startCount } }

        func run() async -> ImageBackdropPolicy {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    _startCount += 1
                    continuations.append(continuation)
                }
            }
        }

        func release(with backdrop: ImageBackdropPolicy) {
            let pending: [CheckedContinuation<ImageBackdropPolicy, Never>] = lock.withLock {
                let value = continuations
                continuations.removeAll()
                return value
            }
            pending.forEach { $0.resume(returning: backdrop) }
        }
    }

    private var writtenPaths: [String] = []

    override func tearDown() async throws {
        writtenPaths.forEach { AttachmentPaths.deleteFile(at: $0) }
        writtenPaths.removeAll()
        try await super.tearDown()
    }

    /// Through the real policy, on the path the single-attachment bubble takes.
    /// Revert-check: fails if `AttachmentThumbnailLoader.publish` stops assigning `imageBackdrop`.
    func testLoad_transparentThumbnail_publishesItsBackdrop() async throws {
        let loader = AttachmentThumbnailLoader()

        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { loader.image != nil }

        XCTAssertEqual(loader.imageBackdrop, .light)
        XCTAssertFalse(loader.isLoading)
    }

    /// Through the real policy, on the path the attachment grid takes.
    /// Revert-check: fails if `loadDownsampled` publishes its image without going through
    /// `AttachmentThumbnailLoader.publish`.
    func testLoadDownsampled_transparentOriginal_publishesItsBackdrop() async throws {
        let loader = AttachmentThumbnailLoader()

        loader.loadDownsampled(
            attachmentId: Self.makeAttachmentID(),
            localPath: try writeTransparentLogo(),
            previewPath: nil,
            targetSize: CGSize(width: 200, height: 200),
            isImage: true
        )
        await waitUntil { loader.image != nil }

        XCTAssertEqual(loader.imageBackdrop, .light)
    }

    /// Revert-check: fails if `publish` assigns `image` before awaiting the backdrop: the image
    /// would draw on the transcript's black until the resolution landed.
    func testLoad_imageWaitsForItsBackdrop() async throws {
        let gate = BackdropGate()
        let loader = makeLoader(gate: gate)

        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { gate.startCount == 1 }

        XCTAssertNil(loader.image)
        XCTAssertTrue(loader.isLoading)

        gate.release(with: .light)
        await waitUntil { loader.image != nil }

        XCTAssertEqual(loader.imageBackdrop, .light)
        XCTAssertFalse(loader.isLoading)
    }

    /// Revert-check: fails if `publish` drops its `guard !Task.isCancelled`: resolving the
    /// backdrop is a suspension the caller's own check cannot see past.
    func testLoad_cancelledWhileResolvingBackdrop_publishesNothing() async throws {
        let gate = BackdropGate()
        let loader = makeLoader(gate: gate)

        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { gate.startCount == 1 }
        loader.cancel()

        gate.release(with: .light)
        // Give the (cancelled) task a chance to run its completion.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
        XCTAssertFalse(loader.isLoading)
    }

    /// Revert-check: fails if `publish` drops its `guard !Task.isCancelled`: the retired
    /// request's image and card would land on the attachment that replaced it.
    func testLoad_newRequestWhileResolvingBackdrop_discardsTheRetiredResult() async throws {
        let gate = BackdropGate()
        let loader = makeLoader(gate: gate)

        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { gate.startCount == 1 }
        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: nil)

        gate.release(with: .light)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
    }

    /// Revert-check: fails if `prepare(for:)` stops clearing `imageBackdrop`: the next
    /// attachment's placeholder state would carry the previous image's verdict.
    func testLoad_newRequest_clearsThePreviousBackdrop() async throws {
        let loader = AttachmentThumbnailLoader()
        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { loader.image != nil }
        XCTAssertEqual(loader.imageBackdrop, .light)

        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: nil)

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
    }

    /// Revert-check: fails if `reset()` stops clearing `imageBackdrop`.
    func testReset_clearsTheBackdrop() async throws {
        let loader = AttachmentThumbnailLoader()
        loader.load(attachmentId: Self.makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { loader.image != nil }
        XCTAssertEqual(loader.imageBackdrop, .light)

        loader.reset()

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
    }

    // MARK: - Helpers

    private func makeLoader(gate: BackdropGate) -> AttachmentThumbnailLoader {
        AttachmentThumbnailLoader(resolveBackdropOperation: { _ in
            await gate.run()
        })
    }

    /// `local_` IDs need no message-scoped path to read as storage.
    private static func makeAttachmentID() -> String {
        "local_backdrop-test-\(UUID().uuidString)"
    }

    /// A black bar on a transparent canvas, the shape of the reported logo.
    private func writeTransparentLogo() throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 1_000, height: 1_000),
            format: format
        ).pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 250, y: 400, width: 500, height: 200))
        }
        AttachmentPaths.setupDirectories()
        let path = AttachmentPaths.previewPath(
            idOrUUID: "backdrop-test-\(UUID().uuidString)",
            ext: "png"
        )
        XCTAssertTrue(AttachmentPaths.saveData(data, to: path))
        writtenPaths.append(path)
        return path
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
