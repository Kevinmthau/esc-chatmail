#if os(iOS)
import UIKit
#endif
import WebKit
import XCTest
@testable import esc_chatmail

/// `FullEmailWebViewManager.releaseIdleWebViews` (architecture review 2026-11,
/// `web-content-rendering#2`): the pooled web views the reader does not hold are torn down when a
/// chat leaves the screen and when the app enters the background on iOS, their prepared payloads
/// stay, and nothing builds a released view again behind the release's back.
@MainActor
final class FullEmailWebViewManagerIdleReleaseTests: XCTestCase {
    private var messagesDirectory: URL!
    private var contentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerIdleReleaseTests-\(UUID().uuidString)"
        )
        contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: messagesDirectory)
        super.tearDown()
    }

    /// Idle views go, payloads stay, and a remote-image fallback post afterwards (which re-warms at
    /// the remembered width) rebuilds none. The first post, before the release, is the control: it
    /// does rebuild the view, so the later absence is the release's doing.
    ///
    /// Revert-check: removing `remoteImageFallbackBookkeeping.forgetWarmWidths()` from
    /// `releaseIdleWebViews` lets the second post rebuild the view and fails this; removing its
    /// teardown loop leaves the view in place and fails it too.
    /// HONEST SCOPE: the absence after the second post is read over a bounded window
    /// (`absenceWindowNanoseconds`).
    func testReleaseIdleWebViews_keepsPayloads_andAFallbackPostRebuildsNoView() async throws {
        let messageId = "idle-release-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(simpleHTML(title: "Idle release"), for: messageId)
        let manager = makeManager()
        defer { manager.clear() }

        await manager.warm(request: makeRequest(messageId: messageId), message: nil, width: 390)
        XCTAssertTrue(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId), "Precondition")

        let firstView = try XCTUnwrap(manager.webViewForTesting(messageId: messageId))
        postRemoteImageFallback(messageId: messageId)
        // Control: the post tears the view down and re-warms at the remembered width, so a
        // different view stands in its place.
        await waitUntil {
            manager.webViewForTesting(messageId: messageId).map { $0 !== firstView } == true
                && manager.activeWarmOperationCountForTesting == 0
        }

        manager.releaseIdleWebViews()

        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId))
        XCTAssertTrue(manager.hasRemoteImageFallbackWarmContextForTesting(messageId: messageId))

        postRemoteImageFallback(messageId: messageId)
        try await Task.sleep(nanoseconds: absenceWindowNanoseconds)
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId), "The re-warm still prepares the payload")
    }

    /// A warm suspended in its HTML preparation when the release lands stores its payload and
    /// builds no view when it resumes.
    ///
    /// Revert-check: dropping `releaseGeneration == idleReleaseGeneration` from `warm`'s web-view
    /// guard fails this.
    func testWarmSuspendedAcrossARelease_storesThePayloadAndBuildsNoView() async {
        let messageId = "idle-release-suspended-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(simpleHTML(title: "Suspended"), for: messageId)
        let manager = makeManager()
        defer { manager.clear() }

        let warm = Task { @MainActor in
            await manager.warm(request: makeRequest(messageId: messageId), message: nil, width: 390)
        }
        await waitUntil(pollIntervalNanoseconds: 0) { manager.activeWarmOperationCountForTesting > 0 }
        manager.releaseIdleWebViews()
        await warm.value

        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId))
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
    }

    #if os(iOS)
    /// The background notification, from the source the manager was given, releases idle views.
    /// The notification goes to a center of the test's own: posted to the default one it would
    /// reach every observer in the test host.
    ///
    /// Revert-check: removing `backgroundEventSource.start` from `FullEmailWebViewManager.init`
    /// fails this.
    func testEnteringTheBackground_releasesIdleViews() async {
        let messageId = "idle-release-background-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(simpleHTML(title: "Background"), for: messageId)
        let center = NotificationCenter()
        let manager = makeManager(backgroundEventSource: AppBackgroundEventSource(notificationCenter: center))
        defer { manager.clear() }

        await manager.warm(request: makeRequest(messageId: messageId), message: nil, width: 390)
        XCTAssertTrue(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId), "Precondition")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId))
    }
    #endif

    /// A chat that leaves the screen releases the pool, through the chat's own dependencies.
    ///
    /// Revert-check: removing the `releaseIdleWebViews()` call from `ChatView`'s `onDisappear`
    /// fails this.
    func testChatView_releasesIdleViewsWhenItDisappears() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/ChatView.swift")
        let disappear = try XCTUnwrap(source.range(of: ".onDisappear {"))
        let body = source[disappear.upperBound...].prefix(600)
        XCTAssertTrue(body.contains("chatDependencies.fullEmailOpener.releaseIdleWebViews()"))
    }

    // MARK: - Fixtures

    private let absenceWindowNanoseconds: UInt64 = 1_000_000_000

    /// The event sources listen to centers of their own, so nothing posted in the test host
    /// reaches this manager. The Mac's take no center: its background source delivers nothing, and
    /// its memory-pressure source is a dispatch source no test can raise.
    private func makeManager(
        backgroundEventSource: AppBackgroundEventSource? = nil
    ) -> FullEmailWebViewManager {
        #if os(iOS)
        FullEmailWebViewManager(
            loader: makeLoader(),
            memoryPressureEventSource: MemoryPressureEventSource(notificationCenter: NotificationCenter()),
            backgroundEventSource: backgroundEventSource ?? AppBackgroundEventSource(notificationCenter: NotificationCenter())
        )
        #else
        FullEmailWebViewManager(
            loader: makeLoader(),
            backgroundEventSource: backgroundEventSource ?? AppBackgroundEventSource()
        )
        #endif
    }

    private func postRemoteImageFallback(messageId: String) {
        NotificationCenter.default.post(
            name: HTMLContentLoader.remoteImageAttachmentFallbackDidWarmNotification,
            object: nil,
            userInfo: [HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey: messageId]
        )
    }

    private func makeLoader() -> OriginalEmailSourceLoader {
        let recoveryService = IdleReleaseNoRecovery()
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
        "<!DOCTYPE html><html><body><h1>\(title)</h1><p>Prepared full email content.</p></body></html>"
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
            if pollIntervalNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
    }
}

/// Recovers nothing: these tests use only HTML saved to their own directory.
private struct IdleReleaseNoRecovery: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? {
        nil
    }
}
