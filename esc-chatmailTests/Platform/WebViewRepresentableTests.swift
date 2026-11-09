import CoreData
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import WebKit
import XCTest
@testable import esc_chatmail

/// `WebViewRepresentable` lets `BaseEmailWebView` and `FullEmailReaderWebView` write make, update
/// and dismantle once, and bridges them to `UIViewRepresentable` on iOS (`NSViewRepresentable` on
/// the Mac). These tests mount the real views in a window, so they show that SwiftUI itself calls
/// through the bridge on each platform; calling `makeWebView` directly could not show that.
///
/// Fixtures go through a main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// because the mounted reader observes its message's context on the main queue.
@MainActor
final class WebViewRepresentableTests: XCTestCase {
    #if os(iOS)
    private typealias HostView = UIView
    #elseif os(macOS)
    private typealias HostView = NSView
    #endif

    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.makeMainQueueViewContext()
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    /// Unmounting the reader must return its adopted, pre-rendered WebView to the pool, which
    /// only `dismantleWebView` does. SwiftUI's own `dismantleUIView`/`dismantleNSView` defaults
    /// are empty.
    ///
    /// Revert-check: deleting `dismantleUIView` from `WebViewRepresentable`'s UIKit extension (on
    /// iOS) or `dismantleNSView` from its AppKit extension (on the Mac) leaves SwiftUI's empty
    /// default in place, so the WebView is never checked in and this fails.
    func testFullReader_mountedThenUnmounted_adoptsInMakeAndChecksInFromDismantle() async throws {
        let message = MessageBuilder()
            .withId("webview-bridge-\(UUID().uuidString)")
            .build(in: context)
        let cidHandler = CIDSchemeHandler(message: nil)
        let pooledWebView = LayoutAwareWKWebView(
            frame: .zero,
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)
        )
        let adopter = RecordingWebViewAdopter(
            checkout: FullEmailWebViewManager.Checkout(webView: pooledWebView, cidHandler: cidHandler)
        )
        let reader = FullEmailReaderWebView(
            htmlContent: "<html><body>Bridge</body></html>",
            sourceSignature: "sha256:webview-bridge",
            readerWidth: 320,
            message: message,
            webViewAdoptionProvider: adopter,
            onLoadFinished: nil,
            onAdoptedPrerendered: nil
        )

        let host = try mountInTestWindow(AnyView(reader.frame(width: 320, height: 480)))
        await waitUntil { self.firstWebView(in: host.view) != nil }

        XCTAssertEqual(adopter.checkoutMessageIds, [message.id])
        XCTAssertTrue(firstWebView(in: host.view) === pooledWebView)
        XCTAssertTrue(adopter.checkins.isEmpty)

        host.rootView = AnyView(EmptyView())
        #if os(iOS)
        host.view.layoutIfNeeded()
        #elseif os(macOS)
        host.view.layoutSubtreeIfNeeded()
        #endif
        await waitUntil { !adopter.checkins.isEmpty }

        XCTAssertEqual(adopter.checkins.map(\.messageId), [message.id])
        XCTAssertTrue(adopter.checkins.first?.webView === pooledWebView)
    }

    #if os(iOS)
    /// A mounted preview must not take touches or scroll, or it swallows transcript scrolling.
    ///
    /// Revert-check: deleting `webView.makeNonInteractive()` from `BaseEmailWebView`'s
    /// `makePreviewWebView` fails this.
    func testPreview_mounted_isNonInteractive() async throws {
        let preview = BaseEmailWebView(
            htmlContent: "<html><body>Preview</body></html>",
            mode: .scaledPreview(scale: 0.5),
            isDarkMode: false
        )

        let host = try mountInTestWindow(preview.frame(width: 320, height: 200))
        await waitUntil { self.firstWebView(in: host.view) != nil }
        let webView = try XCTUnwrap(firstWebView(in: host.view))

        XCTAssertFalse(webView.isUserInteractionEnabled)
        XCTAssertFalse(webView.scrollView.isScrollEnabled)
        XCTAssertFalse(webView.scrollView.bounces)
        XCTAssertEqual(webView.overrideUserInterfaceStyle, .unspecified)
    }
    #elseif os(macOS)
    /// A mounted preview must not take clicks or wheel events, or it swallows transcript
    /// scrolling: on the Mac that is `hitTest(_:)` returning nil. Its appearance is left to the
    /// window, like iOS's `.unspecified`.
    ///
    /// Revert-check: deleting `webView.makeNonInteractive()` from `BaseEmailWebView`'s
    /// `makePreviewWebView` fails this.
    func testPreview_mounted_isNonInteractive() async throws {
        let preview = BaseEmailWebView(
            htmlContent: "<html><body>Preview</body></html>",
            mode: .scaledPreview(scale: 0.5),
            isDarkMode: false
        )

        let host = try mountInTestWindow(preview.frame(width: 320, height: 200))
        await waitUntil { self.firstWebView(in: host.view) != nil }
        let webView = try XCTUnwrap(firstWebView(in: host.view))
        let superview = try XCTUnwrap(webView.superview)
        let middle = NSPoint(x: webView.frame.midX, y: webView.frame.midY)
        XCTAssertGreaterThan(webView.frame.width, 0, "Precondition: the preview is laid out")
        XCTAssertTrue(superview.bounds.contains(middle), "Precondition: the point is inside the preview")

        XCTAssertNil(webView.hitTest(middle))
        XCTAssertNil(webView.appearance)
    }
    #endif

    private func firstWebView(in view: HostView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }
        for subview in view.subviews {
            if let webView = firstWebView(in: subview) {
                return webView
            }
        }
        return nil
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

@MainActor
private final class RecordingWebViewAdopter: FullEmailWebViewAdopting {
    struct Checkin {
        let messageId: String
        let webView: WKWebView
    }

    private let checkoutResult: FullEmailWebViewManager.Checkout
    private(set) var checkoutMessageIds: [String] = []
    private(set) var checkins: [Checkin] = []

    init(checkout: FullEmailWebViewManager.Checkout) {
        self.checkoutResult = checkout
    }

    func checkout(
        messageId: String,
        sourceSignature: String?,
        wrappedHTML: String,
        message: Message?,
        width: CGFloat
    ) -> FullEmailWebViewManager.Checkout? {
        checkoutMessageIds.append(messageId)
        return checkoutResult
    }

    func checkin(messageId: String, webView: WKWebView) -> Bool {
        checkins.append(Checkin(messageId: messageId, webView: webView))
        return true
    }
}
