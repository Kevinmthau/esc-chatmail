#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import esc_chatmail

/// Email HTML naming a loopback host reaches it through no production web view
/// (architecture review 2026-11, `security-privacy#2`, `web-content-rendering#5`). Each test loads
/// one page into one kind of web view, as the app makes and drives it, and counts the connections a
/// listener on 127.0.0.1 received: an `<img>`, a CSS `url()`, an `@font-face` in use, a video
/// poster, `localhost` and `2130706433` (127.0.0.1 as an integer), all at the listener's port. The
/// control test loads the same page with no rule list and must see connections, so a zero below
/// is the list's doing and not the page's.
///
/// iOS only: a Mac test host may not listen without the network-server entitlement.
///
/// HONEST SCOPE: absence is read after the document finished and a further settle of
/// `settleNanoseconds`; a load WebKit starts later than that would not be seen.
@MainActor
final class EmailWebContentPrivateNetworkLoadTests: XCTestCase {
    private var recorder: LoopbackConnectionRecorder!
    private var rules: EmailWebContentNetworkRules!
    private var window: UIWindow!
    private let settleNanoseconds: UInt64 = 1_500_000_000

    override func setUp() async throws {
        try await super.setUp()
        recorder = try LoopbackConnectionRecorder()
        try recorder.start()
        rules = EmailWebContentNetworkRules(
            compile: EmailWebContentNetworkRules.storeCompiler(makeStore: EmailWebContentNetworkRules.temporaryStore)
        )
        let permitted = await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 10_000_000_000)
        XCTAssertTrue(permitted)
        XCTAssertEqual(rules.state, .ready, "Precondition: the production rules compiled")
        window = try makeTestHostWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.isHidden = false
    }

    override func tearDown() async throws {
        recorder.stop()
        window.isHidden = true
        window = nil
        try await super.tearDown()
    }

    private var page: String {
        let port = recorder.port
        return """
        <!DOCTYPE html>
        <html><head><style>
        @font-face { font-family: probe; src: url(http://127.0.0.1:\(port)/font.woff); }
        .bg { background-image: url(http://127.0.0.1:\(port)/css.png); width: 20px; height: 20px; }
        </style></head><body>
        <p style="font-family: probe">Hello</p>
        <div class="bg"></div>
        <img src="http://127.0.0.1:\(port)/img.png" width="20" height="20">
        <img src="http://localhost:\(port)/localhost.png" width="20" height="20">
        <img src="http://2130706433:\(port)/integer.png" width="20" height="20">
        <video poster="http://127.0.0.1:\(port)/poster.png" width="20" height="20"></video>
        </body></html>
        """
    }

    private func neverCompilingRules() -> EmailWebContentNetworkRules {
        EmailWebContentNetworkRules(compile: { _, _, _ in })
    }

    private func makeHostedWebView(configuration: WKWebViewConfiguration) -> LayoutAwareWKWebView {
        let webView = LayoutAwareWKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            configuration: configuration
        )
        window.addSubview(webView)
        addTeardownBlock { @MainActor in
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        return webView
    }

    /// Waits (bounded) for the document to have loaded, then the settle, then asserts the listener
    /// heard nothing.
    private func assertNoLoopbackConnection(
        after webView: WKWebView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitForCompleteDocument(in: webView, file: file, line: line)
        try await Task.sleep(nanoseconds: settleNanoseconds)
        XCTAssertEqual(
            recorder.connectionCount,
            0,
            "Loopback connections: \(recorder.recordedRequestLines.count) recorded",
            file: file,
            line: line
        )
    }

    private func waitForCompleteDocument(
        in webView: WKWebView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let state = try? await webView.evaluateJavaScript("document.readyState") as? String,
               state == "complete",
               let body = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String,
               body.contains("Hello") {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The page did not finish loading", file: file, line: line)
    }

    private func waitForConnection(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recorder.connectionCount > 0 { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return recorder.connectionCount > 0
    }

    // MARK: - Control

    /// The page does reach the listener from a web view without the list, so the zeros below mean
    /// something.
    func testControl_withoutTheRuleList_thePageConnectsToLoopback() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = makeHostedWebView(configuration: configuration)

        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/"))

        let connected = try await waitForConnection(timeout: 10)
        XCTAssertTrue(connected)
    }

    // MARK: - Reader and pool configuration

    /// Revert-check: removing `controller.add(ruleList)` from `EmailWebContentNetworkRules.attach(to:)`,
    /// or the `attach` call from `FullInteractiveEmailWebView.makeConfiguration` together with the
    /// coordinator's, fails this.
    func testReader_madeWithTheSharedConfiguration_reachesNoLoopbackHost() async throws {
        let configuration = FullInteractiveEmailWebView.makeConfiguration(
            cidHandler: CIDSchemeHandler(message: nil),
            networkRules: rules
        )
        XCTAssertTrue(rules.isAttached(to: configuration.userContentController))
        let reader = FullEmailReaderWebView(htmlContent: page, sourceSignature: nil, message: nil)
        let coordinator = FullEmailReaderWebView.Coordinator(reader, networkRules: rules)
        let webView = makeHostedWebView(configuration: configuration)
        webView.navigationDelegate = coordinator

        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(coordinator.lastLoadedContent, page, "Precondition: the reader loaded")
        try await assertNoLoopbackConnection(after: webView)
    }

    /// A reader made before the list compiled has a configuration without it; its coordinator
    /// attaches it before the first load.
    ///
    /// Revert-check: removing the `networkRules.attach(to:)` call from
    /// `FullEmailReaderWebView.Coordinator.loadContentIfReady` (passing `true` instead) fails this.
    func testReader_madeBeforeTheListCompiled_attachesItBeforeItsFirstLoad() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let reader = FullEmailReaderWebView(htmlContent: page, sourceSignature: nil, message: nil)
        let coordinator = FullEmailReaderWebView.Coordinator(reader, networkRules: rules)
        let webView = makeHostedWebView(configuration: configuration)
        webView.navigationDelegate = coordinator

        coordinator.loadContentIfReady(in: webView)

        XCTAssertTrue(rules.isAttached(to: webView.configuration.userContentController))
        try await assertNoLoopbackConnection(after: webView)
    }

    /// While the list compiles the reader loads nothing (`network-rules-pending`), and it loads,
    /// with the list, once the list is ready.
    ///
    /// Revert-check: making `EmailWebViewLoadCoordination.loadReadiness` ignore
    /// `networkRulesPermitLoading` fails this.
    func testReader_whileTheListCompiles_defersItsLoad() async throws {
        let pending = neverCompilingRules()
        let reader = FullEmailReaderWebView(htmlContent: page, sourceSignature: nil, message: nil)
        let coordinator = FullEmailReaderWebView.Coordinator(reader, networkRules: pending)
        let webView = makeHostedWebView(configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator

        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(coordinator.lastLoadedContent, "")
        XCTAssertEqual(
            coordinator.loadReadiness(
                windowPresent: true,
                width: 390,
                height: 600,
                networkRulesPermitLoading: pending.attach(to: webView.configuration.userContentController)
            ),
            .deferred(reason: EmailWebViewLoadCoordination.networkRulesPendingReason)
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)
        XCTAssertEqual(recorder.connectionCount, 0)
    }

    /// The pool makes no web view while the list compiles, so it never hands out a view warmed
    /// without it; the payload is kept.
    ///
    /// Revert-check: removing the `canMakeEntryWithNetworkRules` guard from
    /// `prepaintAfterExplicitOpen` fails this.
    func testPool_whileTheListCompiles_prerendersNothing() {
        let fixture = makePoolFixture(networkRules: neverCompilingRules())
        defer { fixture.manager.clear() }

        fixture.prepaint()

        XCTAssertTrue(fixture.manager.hasPreparedPayloadForTesting(messageId: fixture.messageId))
        XCTAssertFalse(fixture.manager.hasPrerenderedWebViewEntryForTesting(messageId: fixture.messageId))
    }

    /// Revert-check: as for the reader's test; the pool's views come from the same configuration.
    func testPool_prerenderedView_reachesNoLoopbackHost() async throws {
        let fixture = makePoolFixture(networkRules: rules)
        defer { fixture.manager.clear() }

        fixture.prepaint()

        let webView = try XCTUnwrap(fixture.manager.webViewForTesting(messageId: fixture.messageId))
        XCTAssertTrue(rules.isAttached(to: webView.configuration.userContentController))
        try await assertNoLoopbackConnection(after: webView)
    }

    // MARK: - Preview and snapshot

    /// Revert-check: removing the `networkRules.attach(to:)` call from
    /// `BaseEmailWebView.Coordinator.loadContentIfReady` (passing `true` instead) fails this: the
    /// configuration here is made without the list, as one made before it compiled is.
    func testPreview_reachesNoLoopbackHost() async throws {
        let preview = BaseEmailWebView(htmlContent: page, mode: .simplePreview)
        let coordinator = BaseEmailWebView.Coordinator(preview, networkRules: rules)
        let webView = makeHostedWebView(configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator

        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(coordinator.lastLoadedContent, page, "Precondition: the preview loaded")
        try await assertNoLoopbackConnection(after: webView)
    }

    /// Revert-check: removing the `attach` guard from `EmailPreviewSnapshotRenderSession.init`
    /// fails this.
    func testSnapshotSession_reachesNoLoopbackHost() async throws {
        let session = try EmailPreviewSnapshotRenderSession(
            request: makeSnapshotRequest(),
            networkRules: rules
        )

        _ = try? await session.render()

        // The render ends after its own settle (1 s past didFinish); wait the settle again for
        // anything later.
        try await Task.sleep(nanoseconds: settleNanoseconds)
        XCTAssertEqual(recorder.connectionCount, 0)
    }

    /// A render asked for while the list compiles waits for it, then renders with it.
    ///
    /// Revert-check: removing the renderer's `waitUntilLoadingPermitted` makes the session refuse
    /// with `networkRulesPending` at once and fails this.
    func testSnapshotRenderer_waitsForTheListToCompile() async throws {
        var heldCompletion: (@Sendable (WKContentRuleList?, Error?) -> Void)?
        let delayed = EmailWebContentNetworkRules(compile: { _, _, completion in
            heldCompletion = completion
        })
        delayed.prepare()
        let renderer = EmailPreviewSnapshotRenderer(
            scheduler: EmailPreviewSnapshotRenderScheduler(maxConcurrentRenders: 1),
            networkRules: delayed
        )

        let render = Task { @MainActor in
            try await renderer.render(request: makeSnapshotRequest())
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let compiled = try await compileProductionList()
        heldCompletion?(compiled, nil)

        let result = try await render.value
        XCTAssertGreaterThan(result.displayHeight, 0)
        XCTAssertEqual(delayed.state, .ready)
        XCTAssertEqual(recorder.connectionCount, 0)
    }

    /// A render whose wait for the list ends at its bound fails, and loads nothing.
    func testSnapshotRenderer_listNeverCompiles_failsWithoutLoading() async throws {
        let renderer = EmailPreviewSnapshotRenderer(
            scheduler: EmailPreviewSnapshotRenderScheduler(maxConcurrentRenders: 1),
            networkRules: neverCompilingRules(),
            networkRulesWaitNanoseconds: 100_000_000
        )

        do {
            _ = try await renderer.render(request: makeSnapshotRequest())
            XCTFail("A render must not build its session without the list")
        } catch EmailPreviewSnapshotRenderError.networkRulesPending {
        }
        XCTAssertEqual(recorder.connectionCount, 0)
    }

    // MARK: - Fixtures

    private func makeSnapshotRequest() -> EmailPreviewSnapshotRequest {
        EmailPreviewSnapshotRequest(
            html: page,
            cacheKey: "private-network-\(UUID().uuidString)",
            containerWidth: 280,
            isDarkMode: false,
            senderEmail: "news@example.com",
            message: nil
        )
    }

    private func compileProductionList() async throws -> WKContentRuleList {
        let store = try XCTUnwrap(EmailWebContentNetworkRules.temporaryStore())
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: "test-\(UUID().uuidString)",
                encodedContentRuleList: EmailWebContentNetworkRuleSource.encodedRuleList
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    private struct PoolFixture {
        let manager: FullEmailWebViewManager
        let messageId: String
        let message: Message
        let request: OriginalEmailWarmRequest
        let artifact: EmailReaderArtifact
        let stack: TestCoreDataStack

        @MainActor
        func prepaint() {
            manager.prepaintAfterExplicitOpen(
                request: request,
                message: message,
                artifact: artifact,
                width: 390
            )
        }
    }

    private func makePoolFixture(networkRules: EmailWebContentNetworkRules) -> PoolFixture {
        let stack = TestCoreDataStack()
        let messageId = "private-network-pool-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withSubject("Subject")
            .withSender(email: "sender@example.com", name: "Sender")
            .withBody("Body \(messageId)")
            .build(in: stack.viewContext)
        let html = page
        let artifact = EmailReaderArtifact(
            messageID: messageId,
            sourceSignature: "sha256:\(messageId)",
            body: .html(html),
            metadata: EmailMetadataSnapshot(message: message),
            inlineAttachmentAvailabilitySignature: InlineCIDAttachmentAvailabilityFingerprint.make(
                html: html,
                message: message
            ),
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            producedAt: Date(timeIntervalSince1970: 0)
        )
        let request = OriginalEmailWarmRequest(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Body \(messageId)",
            senderEmail: "sender@example.com",
            subject: "Subject"
        )
        return PoolFixture(
            manager: FullEmailWebViewManager(networkRules: networkRules),
            messageId: messageId,
            message: message,
            request: request,
            artifact: artifact,
            stack: stack
        )
    }
}
#endif
