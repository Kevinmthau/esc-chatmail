#if os(iOS)
import UIKit
#endif
import CoreData
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
    private var testStack: TestCoreDataStack!
    /// Main-queue, so the suite's main-actor bodies touch it on its queue.
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.makeMainQueueViewContext()
        messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerIdleReleaseTests-\(UUID().uuidString)"
        )
        contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
    }

    override func tearDown() {
        context = nil
        testStack = nil
        try? FileManager.default.removeItem(at: messagesDirectory)
        super.tearDown()
    }

    /// Idle views go, payloads stay, and a remote-image fallback post afterwards (which re-warms at
    /// the remembered width) rebuilds none. The first post, before the release, is the control: it
    /// does rebuild the view, so the later absence is the release's doing.
    ///
    /// Revert-check: removing `remoteImageFallbackBookkeeping.forgetWarmWidths()` from
    /// `releaseIdleWebViews` lets the second post rebuild the view and fails this; removing its
    /// teardown loop leaves the released view in the off-screen window with its delegate, and
    /// fails it too (the entry is dropped either way, so only the view itself shows it).
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

        let pooledView = try XCTUnwrap(manager.webViewForTesting(messageId: messageId))
        XCTAssertNotNil(pooledView.superview, "Precondition: the pooled view is in the off-screen window")
        XCTAssertNotNil(pooledView.navigationDelegate, "Precondition: the pool's delegate is set")

        manager.releaseIdleWebViews()

        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
        XCTAssertNil(pooledView.superview, "The released view is torn down")
        XCTAssertNil(pooledView.navigationDelegate, "The released view is torn down")
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

    /// An open's prewarm suspended in its warm when the release lands builds no view when it
    /// resumes: its warm builds none, and neither may the prepaint after it, which a closed chat
    /// or a backgrounded app would otherwise get as an off-screen view loading the email's remote
    /// resources.
    ///
    /// Revert-check: dropping `releaseGeneration == self.idleReleaseGeneration` from
    /// `prewarmOnOpen`'s guard fails this.
    func testPrewarmOnOpenSuspendedAcrossARelease_buildsNoView() async throws {
        let messageId = "idle-release-prewarm-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(simpleHTML(title: "Prewarm"), for: messageId)
        let message = try makeMessage(id: messageId)
        let manager = makeManager()
        defer { manager.clear() }

        manager.prewarmOnOpen(message: message, width: 390)
        await waitUntil(pollIntervalNanoseconds: 0) { manager.activeWarmOperationCountForTesting > 0 }
        manager.releaseIdleWebViews()
        await manager.waitForPrewarmTasksForTesting()

        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId))
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId))
    }

    #if os(iOS)
    /// From the background notification until the app is about to return, nothing builds a web
    /// view: not an open's prewarm that runs then, and not a reader left open behind the release
    /// that prepaints on a content change. Back in the foreground the same prewarm builds one,
    /// which is the control.
    ///
    /// Revert-check: dropping `!isAppInBackground` from `warm`'s web-view guard, or from
    /// `prepaintAfterExplicitOpen`'s, or not clearing it on the foreground notification, fails
    /// this (each run alone).
    func testWhileInTheBackground_nothingBuildsAView_untilTheAppReturns() async throws {
        let messageId = "idle-release-backgrounded-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(simpleHTML(title: "Backgrounded"), for: messageId)
        let message = try makeMessage(id: messageId)
        let center = NotificationCenter()
        let manager = makeManager(backgroundEventSource: AppBackgroundEventSource(notificationCenter: center))
        defer { manager.clear() }

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        manager.prewarmOnOpen(message: message, width: 390)
        await manager.waitForPrewarmTasksForTesting()

        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: messageId))
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId), "The prewarm builds none")

        let request = makeRequest(for: message)
        let prepared = try XCTUnwrap(manager.preparedOpenArtifact(request: request, message: message, width: 390))
        manager.prepaintAfterExplicitOpen(request: request, message: message, artifact: prepared.artifact, width: 390)
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId), "The reader's prepaint builds none")

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        manager.prewarmOnOpen(message: message, width: 390)
        await manager.waitForPrewarmTasksForTesting()

        XCTAssertTrue(
            manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId),
            "Control: back in the foreground the same prewarm builds the view"
        )
    }

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
        let path = "esc-chatmail/Views/Chat/ChatView.swift"
        let source = try repositorySource(path)
        // Every `onDisappear` block, read to its closing brace, so the call is found wherever in
        // the block it moves and only inside one.
        var blocks: [String] = []
        var searchStart = source.startIndex
        while let marker = source.range(of: ".onDisappear {", range: searchStart..<source.endIndex) {
            let tail = String(source[marker.lowerBound...])
            let body = try sourceBlockRange(after: ".onDisappear {", open: "{", close: "}", in: tail, path: path)
            blocks.append(String(tail[body]))
            searchStart = marker.upperBound
        }
        XCTAssertFalse(blocks.isEmpty, "\(path) no longer has an `.onDisappear` block")
        XCTAssertTrue(blocks.contains { $0.contains("chatDependencies.fullEmailOpener.releaseIdleWebViews()") })
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

    /// A stored message for the open paths, which take one.
    private func makeMessage(id: String) throws -> Message {
        let message = MessageBuilder()
            .withId(id)
            .build(in: context)
        try context.save()
        return message
    }

    /// The request `prewarmOnOpen` builds from `message`.
    private func makeRequest(for message: Message) -> OriginalEmailWarmRequest {
        OriginalEmailWarmRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            subject: message.subject
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
