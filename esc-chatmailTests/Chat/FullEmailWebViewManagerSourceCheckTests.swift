import XCTest
@testable import esc_chatmail

/// An open of a warmed email checks its source without reading and hashing the body when the
/// message file's signature (a stat) is still the one the warm saw before its read
/// (architecture review 2026-11, `web-content-rendering#4`). A changed file falls back to the
/// content check, which alone decides whether the payload is reused.
@MainActor
final class FullEmailWebViewManagerSourceCheckTests: XCTestCase {
    private var messagesDirectory: URL!
    private var contentHandler: HTMLContentHandler!
    private var canonicalLoader: RecordingCanonicalLoader!

    override func setUp() {
        super.setUp()
        messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerSourceCheckTests-\(UUID().uuidString)"
        )
        contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        canonicalLoader = RecordingCanonicalLoader(
            base: CanonicalEmailContentLoader(contentHandler: contentHandler, recoveryService: SourceCheckNoRecovery())
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: messagesDirectory)
        super.tearDown()
    }

    /// Revert-check: making `currentSourceSignature(for:request:)` always run the content check
    /// (comparing against a different signature) fails this.
    func testOpen_unchangedMessageFile_skipsTheContentCheck() async throws {
        let (manager, request) = await warmedManager(html: "<html><body><p>Unchanged</p></body></html>")
        defer { manager.clear() }
        let checksBefore = canonicalLoader.contentCheckCount

        let prepared = manager.preparedOpenArtifact(request: request, message: nil, width: nil)

        XCTAssertNotNil(prepared)
        XCTAssertEqual(canonicalLoader.contentCheckCount - checksBefore, 0)
    }

    /// A rewritten file has a new signature, so the content check runs: other content makes the
    /// payload stale, the same content rewritten keeps it.
    func testOpen_rewrittenMessageFile_runsTheContentCheck() async throws {
        let original = "<html><body><p>Original</p></body></html>"
        let (manager, request) = await warmedManager(html: original)
        defer { manager.clear() }

        _ = contentHandler.saveHTML(original, for: request.messageId)
        let checksBeforeSame = canonicalLoader.contentCheckCount
        let sameContent = manager.preparedOpenArtifact(request: request, message: nil, width: nil)
        XCTAssertNotNil(sameContent, "The same content rewritten is still reusable")
        XCTAssertEqual(canonicalLoader.contentCheckCount - checksBeforeSame, 1)

        _ = contentHandler.saveHTML("<html><body><p>Changed</p></body></html>", for: request.messageId)
        let checksBeforeChanged = canonicalLoader.contentCheckCount
        let changedContent = manager.preparedOpenArtifact(request: request, message: nil, width: nil)
        XCTAssertNil(changedContent, "Changed content makes the payload stale")
        XCTAssertEqual(canonicalLoader.contentCheckCount - checksBeforeChanged, 1)
    }

    /// The warm records the message file's signature for a body read from it.
    ///
    /// Revert-check: passing no signature to `WarmedOriginalEmailHTML` from
    /// `warmOriginalEmailSource` fails this.
    /// HONEST SCOPE: that the signature is taken before the read, which is what keeps a write
    /// between the two from being trusted, is not observable here.
    func testWarm_recordsTheMessageFileSignature() async throws {
        let messageId = "source-check-signature-\(UUID().uuidString)"
        _ = contentHandler.saveHTML("<html><body><p>Signed</p></body></html>", for: messageId)
        let loader = makeLoader()

        let maybeWarmed = await loader.warmOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "sender@example.com",
            subject: "Subject"
        )
        let warmed = try XCTUnwrap(maybeWarmed)

        XCTAssertEqual(warmed.sourceLocation, .messageFile)
        XCTAssertNotNil(warmed.messageFileSignature)
        XCTAssertEqual(
            warmed.messageFileSignature,
            contentHandler.messageFileSignature(for: messageId, expectedGeneration: nil)
        )
    }

    // MARK: - Fixtures

    private func warmedManager(html: String) async -> (FullEmailWebViewManager, OriginalEmailWarmRequest) {
        let messageId = "source-check-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(html, for: messageId)
        let request = OriginalEmailWarmRequest(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Body \(messageId)",
            senderEmail: "sender@example.com",
            subject: "Subject"
        )
        let manager = FullEmailWebViewManager(loader: makeLoader())
        await manager.warm(request: request, message: nil, width: nil)
        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId), "Precondition")
        return (manager, request)
    }

    private func makeLoader() -> OriginalEmailSourceLoader {
        let recoveryService = SourceCheckNoRecovery()
        return OriginalEmailSourceLoader(
            canonicalContentLoader: canonicalLoader,
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
}

/// Forwards to a real loader and counts the content checks (`currentHTMLSourceSignature`, which
/// reads and hashes the body). `@unchecked Sendable`: the count is kept under `lock`; `base` is set
/// once.
private final class RecordingCanonicalLoader: CanonicalEmailContentLoading, @unchecked Sendable {
    private let base: CanonicalEmailContentLoader
    private let lock = NSLock()
    private var contentChecks = 0

    init(base: CanonicalEmailContentLoader) {
        self.base = base
    }

    var contentCheckCount: Int {
        lock.withLock { contentChecks }
    }

    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        allowRecovery: Bool
    ) async -> CanonicalEmailContent? {
        await base.loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery
        )
    }

    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        allowRecovery: Bool,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) async -> CanonicalEmailContent? {
        await base.loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery,
            expectedAccountGeneration: expectedAccountGeneration
        )
    }

    func recoverCanonicalEmailContent(messageId: String, bodyText: String?) async -> CanonicalEmailContent? {
        await base.recoverCanonicalEmailContent(messageId: messageId, bodyText: bodyText)
    }

    func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) async -> CanonicalEmailContent? {
        await base.recoverCanonicalEmailContent(
            messageId: messageId,
            bodyText: bodyText,
            expectedAccountGeneration: expectedAccountGeneration
        )
    }

    func currentHTMLSourceSignature(messageId: String, bodyStorageURI: String?) -> String? {
        lock.withLock { contentChecks += 1 }
        return base.currentHTMLSourceSignature(messageId: messageId, bodyStorageURI: bodyStorageURI)
    }

    func currentMessageFileSignature(messageId: String) -> String? {
        base.currentMessageFileSignature(messageId: messageId)
    }
}

/// Recovers nothing: these tests use only HTML saved to their own directory.
private struct SourceCheckNoRecovery: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? {
        nil
    }
}
