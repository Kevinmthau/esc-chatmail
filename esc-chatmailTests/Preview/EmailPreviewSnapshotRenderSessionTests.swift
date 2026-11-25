import WebKit
import XCTest
@testable import esc_chatmail

/// The off-screen snapshot render's own `WKWebView`, ended by a WebContent process termination.
@MainActor
final class EmailPreviewSnapshotRenderSessionTests: XCTestCase {
    // Revert-check: fails if `EmailPreviewSnapshotRenderSession.webViewWebContentProcessDidTerminate`
    // is removed. The render then waits out its 5 s timeout and throws `.timeout` (and WebKit is
    // left to reload the dead view by itself, which for a load in progress fetched its base URL).
    func testWebContentTermination_failsTheRenderAtOnceWithTheTerminationError() async throws {
        let session = try EmailPreviewSnapshotRenderSession(
            request: EmailPreviewSnapshotRequest(
                html: "<html><body><p>Preview</p></body></html>",
                cacheKey: "terminated-render-\(UUID().uuidString)",
                containerWidth: 280,
                isDarkMode: false,
                senderEmail: "news@sender.example",
                message: nil
            )
        )
        let start = Date()
        let render = Task { @MainActor in
            try await session.render()
        }
        await waitUntil { session.isAwaitingRenderForTesting }

        // Called through the protocol's optional requirement, as WebKit finds it.
        let delegate: any WKNavigationDelegate = session
        delegate.webViewWebContentProcessDidTerminate?(WKWebView(frame: .zero))

        do {
            _ = try await render.value
            XCTFail("A render whose WebContent process died must not succeed")
        } catch EmailPreviewSnapshotRenderError.navigationFailed(let underlying) {
            let nsError = underlying as NSError
            XCTAssertEqual(nsError.domain, WKErrorDomain)
            XCTAssertEqual(nsError.code, WKError.Code.webContentProcessTerminated.rawValue)
        } catch {
            XCTFail("Expected navigationFailed(webContentProcessTerminated), got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0, "The render must not wait for its timeout")
        XCTAssertFalse(session.isAwaitingRenderForTesting)
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
