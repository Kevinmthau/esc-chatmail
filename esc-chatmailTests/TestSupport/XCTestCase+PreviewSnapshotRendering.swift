#if os(iOS)
import XCTest
@testable import esc_chatmail

extension XCTestCase {
    /// Renders a preview snapshot through the app's renderer and its scheduler, rendering again
    /// after a `.timeout` until `timeout` has passed.
    ///
    /// WebKit's content and GPU processes spawn lazily in the test host, and on a loaded CI runner
    /// that spawn is not bounded by any single render's 5 s production budget. PR #115 added a
    /// one-shot warm-up render on the theory that the spawn it forced would leave WebKit warm; the
    /// CI runs for PRs #233 and #236 falsified that: `testRendererKeepsShortPreviewAtDefaultHeight`
    /// failed at 10.3 s and 10.5 s with the warm-up and the assertion render both timing out while
    /// WebKit logged "WebContent process ... took 4.09 seconds to launch" and
    /// `WebProcessProxy::didBecomeUnresponsive`. The GPU process also idle-exits between renders,
    /// so a "warm" render can still pay a relaunch (the next test took 4.1 s in that run).
    ///
    /// The tests that call this assert measured heights, painted pixels and completeness, not the
    /// timeout budget (the timeout → MiniEmailWebView fallback is covered with stub renderers), so
    /// a `.timeout` is retried until a wall-clock deadline instead of failing the test. Any other
    /// error fails at once, and a renderer that never succeeds still fails when the deadline
    /// passes. The production timeout is unchanged.
    @MainActor
    func renderRetryingWebKitStartupTimeouts(
        _ request: EmailPreviewSnapshotRequest,
        timeout: TimeInterval = 45.0
    ) async throws -> EmailPreviewSnapshotResult {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try await EmailPreviewSnapshotRenderer.shared.render(request: request)
            } catch EmailPreviewSnapshotRenderError.timeout where Date() < deadline {
                continue
            }
        }
    }
}
#endif
