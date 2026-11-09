#if os(iOS)
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
    private var attachmentIDs: [String] = []

    override func tearDown() async throws {
        writtenPaths.forEach { AttachmentPaths.deleteFile(at: $0) }
        writtenPaths.removeAll()
        for attachmentID in attachmentIDs {
            await AttachmentCacheActor.shared.removeFromCache(attachmentID)
        }
        attachmentIDs.removeAll()
        try await super.tearDown()
    }

    /// Through the real policy, on the path the single-attachment bubble takes.
    /// Revert-check: fails if `AttachmentThumbnailLoader.publish` stops assigning `imageBackdrop`.
    func testLoad_transparentThumbnail_publishesItsBackdrop() async throws {
        let loader = AttachmentThumbnailLoader()

        loader.load(attachmentId: makeAttachmentID(), previewPath: try writeTransparentLogo())
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
            attachmentId: makeAttachmentID(),
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
    func testLoad_backdropStillResolving_holdsTheImageBack() async throws {
        let gate = BackdropGate()
        let loader = makeLoader(gate: gate)

        loader.load(attachmentId: makeAttachmentID(), previewPath: try writeTransparentLogo())
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

        loader.load(attachmentId: makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { gate.startCount == 1 }
        let retiredLoad = try XCTUnwrap(loader.loadTask)
        loader.cancel()

        gate.release(with: .light)
        // Its end, not a delay: past this the retired load has no way left to publish.
        await retiredLoad.value

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
        XCTAssertFalse(loader.isLoading)
    }

    /// Revert-check: fails if `publish` drops its `guard !Task.isCancelled`: the retired
    /// request's image and card would land on the attachment that replaced it.
    func testLoad_newRequestWhileResolvingBackdrop_discardsTheRetiredResult() async throws {
        let gate = BackdropGate()
        let loader = makeLoader(gate: gate)

        loader.load(attachmentId: makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { gate.startCount == 1 }
        let retiredLoad = try XCTUnwrap(loader.loadTask)
        loader.load(attachmentId: makeAttachmentID(), previewPath: nil)

        gate.release(with: .light)
        await retiredLoad.value

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
    }

    /// Revert-check: fails if `prepare(for:)` stops clearing `imageBackdrop`: the next
    /// attachment's placeholder state would carry the previous image's verdict.
    func testLoad_newRequest_clearsThePreviousBackdrop() async throws {
        let loader = AttachmentThumbnailLoader()
        loader.load(attachmentId: makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { loader.image != nil }
        XCTAssertEqual(loader.imageBackdrop, .light)

        loader.load(attachmentId: makeAttachmentID(), previewPath: nil)

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
    }

    /// Revert-check: fails if `reset()` stops clearing `imageBackdrop`.
    func testReset_afterLoad_clearsTheBackdrop() async throws {
        let loader = AttachmentThumbnailLoader()
        loader.load(attachmentId: makeAttachmentID(), previewPath: try writeTransparentLogo())
        await waitUntil { loader.image != nil }
        XCTAssertEqual(loader.imageBackdrop, .light)

        loader.reset()

        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.imageBackdrop, .none)
    }

    // MARK: - Oversized images

    /// The thumbnail of an oversized white logo is a white JPEG, with no sign left of the logo.
    /// The original still has it, which is why the bubble's oversized path reads that.
    /// Revert-check: fails if `loadDownsampled` prefers the preview over the original.
    func testLoadDownsampled_oversizedWhiteLogo_findsTheCardItsThumbnailLost() async throws {
        let original = makeTransparentLogo(color: .white, canvas: 2_000)
        let thumbnail = try XCTUnwrap(ImageProcessor.generateThumbnail(from: original, mimeType: "image/png"))
        let originalPath = try write(original)
        let previewPath = try write(thumbnail)

        let thumbnailLoader = AttachmentThumbnailLoader()
        thumbnailLoader.load(attachmentId: makeAttachmentID(), previewPath: previewPath)
        await waitUntil { thumbnailLoader.image != nil }
        XCTAssertEqual(thumbnailLoader.imageBackdrop, .none)

        let originalLoader = AttachmentThumbnailLoader()
        originalLoader.loadDownsampled(
            attachmentId: makeAttachmentID(),
            localPath: originalPath,
            previewPath: previewPath,
            targetSize: CGSize(width: 280, height: 280),
            isImage: true
        )
        await waitUntil { originalLoader.image != nil }
        XCTAssertEqual(originalLoader.imageBackdrop, .dark)
    }

    // MARK: - The pixel check's cost

    /// Scrolling away cancels the load, and that has to reach the detached check.
    /// Revert-check: fails if `ImageBackdropPolicy.resolve(for:analyze:)` drops its
    /// `withTaskCancellationHandler`: the check runs out its deadline without seeing the cancel.
    func testLoad_cancelledDuringThePixelCheck_cancelsTheCheck() async throws {
        let probe = CancellationProbe()
        let loader = AttachmentThumbnailLoader(resolveBackdropOperation: { image in
            await ImageBackdropPolicy.resolve(for: image, analyze: { _ in probe.runUntilCancelled() })
        })

        loader.load(attachmentId: makeAttachmentID(), previewPath: try write(makeTransparentLogo()))
        await waitUntil { probe.didStart }
        let retiredLoad = try XCTUnwrap(loader.loadTask)
        loader.cancel()
        await retiredLoad.value

        XCTAssertTrue(probe.sawCancellation)
        XCTAssertNil(loader.image)
    }

    /// A row scrolling back into view gets a new loader but the same cached image.
    /// Revert-check: fails if `ImageBackdropPolicy.resolve(for:analyze:)` stops reading the stored
    /// verdict, or if `AttachmentCacheActor` stops handing back the instance holding it.
    func testLoad_sameAttachmentInANewLoader_checksThePixelsOnce() async throws {
        let counter = AnalysisCounter()
        let attachmentID = makeAttachmentID()
        let previewPath = try write(makeTransparentLogo())

        for _ in 0..<2 {
            let loader = AttachmentThumbnailLoader(resolveBackdropOperation: { image in
                await ImageBackdropPolicy.resolve(for: image, analyze: { cgImage in
                    counter.increment()
                    return ImageBackdropPolicy.resolve(for: cgImage)
                })
            })
            loader.load(attachmentId: attachmentID, previewPath: previewPath)
            await waitUntil { loader.image != nil }
            XCTAssertEqual(loader.imageBackdrop, .light)
        }

        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - Helpers

    /// Stands in for the check, holding it open until it is cancelled or a deadline passes.
    /// Lock-guarded because it runs off the MainActor.
    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _didStart = false
        private var _sawCancellation = false

        var didStart: Bool { lock.withLock { _didStart } }
        var sawCancellation: Bool { lock.withLock { _sawCancellation } }

        func runUntilCancelled() -> ImageBackdropPolicy {
            lock.withLock { _didStart = true }
            let deadline = Date().addingTimeInterval(5)
            while !Task.isCancelled, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            let wasCancelled = Task.isCancelled
            lock.withLock { _sawCancellation = wasCancelled }
            return .none
        }
    }

    /// Lock-guarded because the analysis runs off the MainActor.
    private final class AnalysisCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0

        var count: Int { lock.withLock { _count } }

        func increment() {
            lock.withLock { _count += 1 }
        }
    }

    private func makeLoader(gate: BackdropGate) -> AttachmentThumbnailLoader {
        AttachmentThumbnailLoader(resolveBackdropOperation: { _ in
            await gate.run()
        })
    }

    /// `local_` IDs need no message-scoped path to read as storage.
    private func makeAttachmentID() -> String {
        let attachmentID = "local_backdrop-test-\(UUID().uuidString)"
        attachmentIDs.append(attachmentID)
        return attachmentID
    }

    /// A black bar on a transparent canvas, the shape of the reported logo.
    private func writeTransparentLogo() throws -> String {
        try write(makeTransparentLogo())
    }

    private func makeTransparentLogo(color: UIColor = .black, canvas: CGFloat = 1_000) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: canvas, height: canvas),
            format: format
        ).pngData { context in
            color.setFill()
            context.fill(CGRect(x: canvas * 0.25, y: canvas * 0.4, width: canvas * 0.5, height: canvas * 0.2))
        }
    }

    private func write(_ data: Data) throws -> String {
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
#endif
