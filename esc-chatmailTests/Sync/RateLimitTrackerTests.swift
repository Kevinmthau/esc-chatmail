import XCTest
@testable import esc_chatmail

/// Deterministic arithmetic tests for RateLimitTracker. These intentionally
/// avoid end-to-end concurrency scenarios (timing-flaky) and don't pin exact
/// recovery semantics beyond the credit magnitude — the accounting model is
/// a stopgap (see recordSuccess) slated for a structural rewrite.
final class RateLimitTrackerTests: XCTestCase {

    func testBackoffAccumulatesTowardAbortThreshold() async {
        let tracker = RateLimitTracker()

        await tracker.recordBackoff(60)
        var shouldAbort = await tracker.shouldAbort()
        XCTAssertFalse(shouldAbort)

        await tracker.recordBackoff(60)
        shouldAbort = await tracker.shouldAbort()
        XCTAssertTrue(shouldAbort, "120s cumulative backoff should trip the breaker")
    }

    func testSuccessCreditIsSmall() async {
        let tracker = RateLimitTracker()
        await tracker.recordBackoff(130)

        // A handful of interleaved successes (one concurrent batch) must not
        // wipe a tripped breaker the way the previous 30s credit did (4×30s
        // erased 120s; 4×2s barely dents it).
        for _ in 0..<4 {
            await tracker.recordSuccess()
        }

        let remaining = await tracker.currentCumulativeBackoff
        XCTAssertEqual(remaining, 122, accuracy: 0.001)
        let shouldAbort = await tracker.shouldAbort()
        XCTAssertTrue(shouldAbort)
    }

    func testSustainedSuccessesEventuallyClearBackoff() async {
        let tracker = RateLimitTracker()
        await tracker.recordBackoff(10)

        for _ in 0..<5 {
            await tracker.recordSuccess()
        }

        let remaining = await tracker.currentCumulativeBackoff
        XCTAssertEqual(remaining, 0, accuracy: 0.001)
    }

    func testSuccessCreditNeverGoesNegative() async {
        let tracker = RateLimitTracker()
        await tracker.recordSuccess()
        let remaining = await tracker.currentCumulativeBackoff
        XCTAssertEqual(remaining, 0, accuracy: 0.001)
    }
}
