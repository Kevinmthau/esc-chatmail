import XCTest
@testable import esc_chatmail

/// Characterization tests for `InFlightRequestManager` and its throwing variant.
///
/// This actor is the request-deduplication + failure-tracking primitive the
/// image / attachment caches rely on, so its contract needs to be pinned before
/// the image-cache consolidation work touches those callers.
///
/// The concurrent-dedup test uses a gate so the first operation is provably
/// still in flight when the second caller arrives — deterministic, and it cannot
/// hang because `signal()` is always reached and the spin is bounded.
final class InFlightRequestManagerTests: XCTestCase {

    // MARK: - Deduplication

    func testConcurrentSameKey_dedupsToSingleOperation() async {
        let manager = InFlightRequestManager<String, Int>()
        let runCount = AsyncCounter()
        let gate = ContinuationGate()

        async let first: Int? = manager.deduplicated(key: "k") {
            await runCount.increment()
            await gate.wait()
            return 7
        }

        // Wait until the first operation has registered as in-flight. The gate
        // keeps it in flight, so this terminates. Bound by wall-clock deadline,
        // not yield count: under a loaded cooperative pool (parallel testing)
        // a fixed number of yields can elapse before `first` ever schedules.
        let registrationDeadline = Date().addingTimeInterval(10)
        while await manager.isInFlight("k") == false && Date() < registrationDeadline {
            await Task.yield()
        }
        let registered = await manager.isInFlight("k")
        XCTAssertTrue(registered, "first operation never registered as in-flight")

        async let second: Int? = manager.deduplicated(key: "k") {
            await runCount.increment() // must NOT run — should dedupe onto `first`
            return -1
        }

        // Don't release the gate until the second caller has actually joined
        // the in-flight task. `async let` only starts the child task; under a
        // loaded cooperative pool it may not reach `deduplicated` before the
        // first operation would otherwise complete and deregister.
        let joinDeadline = Date().addingTimeInterval(10)
        while await manager.joinedExistingCount == 0 && Date() < joinDeadline {
            await Task.yield()
        }
        let joined = await manager.joinedExistingCount
        XCTAssertEqual(joined, 1, "second caller never joined the in-flight operation")

        await gate.signal()

        let v1 = await first
        let v2 = await second

        XCTAssertEqual(v1, 7)
        XCTAssertEqual(v2, 7, "second caller should receive the shared in-flight result")
        let count = await runCount.value
        XCTAssertEqual(count, 1, "operation should run exactly once for concurrent same-key callers")
    }

    func testInFlightCount_isZeroAfterCompletion() async {
        let manager = InFlightRequestManager<String, Int>()

        _ = await manager.deduplicated(key: "k") { 1 }

        let inFlight = await manager.isInFlight("k")
        let count = await manager.inFlightCount()
        XCTAssertFalse(inFlight)
        XCTAssertEqual(count, 0)
    }

    func testSequentialCallsForDifferentKeys_eachRunOnce() async {
        let manager = InFlightRequestManager<String, Int>()
        let runCount = AsyncCounter()

        _ = await manager.deduplicated(key: "a") { await runCount.increment(); return 1 }
        _ = await manager.deduplicated(key: "b") { await runCount.increment(); return 2 }

        let count = await runCount.value
        XCTAssertEqual(count, 2)
    }

    // MARK: - Failure tracking

    func testNilResult_marksKeyAsFailed() async {
        let manager = InFlightRequestManager<String, Int>()

        _ = await manager.deduplicated(key: "k") { nil }

        let failed = await manager.hasFailed("k")
        XCTAssertTrue(failed)
    }

    func testSuccessAfterFailure_clearsFailure() async {
        let manager = InFlightRequestManager<String, Int>()

        _ = await manager.deduplicated(key: "k") { nil }
        _ = await manager.deduplicated(key: "k") { 1 }

        let failed = await manager.hasFailed("k")
        XCTAssertFalse(failed)
    }

    func testDeduplicatedWithFailureTracking_skipsPreviouslyFailedKey() async {
        let manager = InFlightRequestManager<String, Int>()
        let runCount = AsyncCounter()

        _ = await manager.deduplicated(key: "k") { nil } // mark failed

        let result = await manager.deduplicatedWithFailureTracking(key: "k", skipIfFailed: true) {
            await runCount.increment() // must NOT run
            return 99
        }

        XCTAssertNil(result)
        let count = await runCount.value
        XCTAssertEqual(count, 0, "operation must be skipped for a previously-failed key")
    }

    func testDeduplicatedWithFailureTracking_runsWhenSkipDisabled() async {
        let manager = InFlightRequestManager<String, Int>()
        let runCount = AsyncCounter()

        _ = await manager.deduplicated(key: "k") { nil } // mark failed

        let result = await manager.deduplicatedWithFailureTracking(key: "k", skipIfFailed: false) {
            await runCount.increment()
            return 99
        }

        XCTAssertEqual(result, 99)
        let count = await runCount.value
        XCTAssertEqual(count, 1)
    }

    func testClearFailedKeys_allowsRetry() async {
        let manager = InFlightRequestManager<String, Int>()
        _ = await manager.deduplicated(key: "k") { nil }

        await manager.clearFailedKeys()

        let failed = await manager.hasFailed("k")
        XCTAssertFalse(failed)
    }

    func testClearFailure_forSpecificKeyOnly() async {
        let manager = InFlightRequestManager<String, Int>()
        _ = await manager.deduplicated(key: "a") { nil }
        _ = await manager.deduplicated(key: "b") { nil }

        await manager.clearFailure(for: "a")

        let aFailed = await manager.hasFailed("a")
        let bFailed = await manager.hasFailed("b")
        XCTAssertFalse(aFailed)
        XCTAssertTrue(bFailed)
    }

    func testFailedKeySet_isBoundedByMaxFailedKeys() async {
        let manager = InFlightRequestManager<String, Int>(maxFailedKeys: 2)

        _ = await manager.deduplicated(key: "a") { nil }
        _ = await manager.deduplicated(key: "b") { nil }
        _ = await manager.deduplicated(key: "c") { nil }

        // Inserting a 3rd distinct failure past the cap of 2 must evict one, so
        // exactly two of the three keys remain tracked as failed.
        var stillFailed = 0
        for key in ["a", "b", "c"] where await manager.hasFailed(key) {
            stillFailed += 1
        }
        XCTAssertEqual(stillFailed, 2)
    }

    // MARK: - Throwing variant

    func testThrowingVariant_success_returnsValueAndClearsInFlight() async throws {
        let manager = ThrowingInFlightRequestManager<String, Int>()

        let value = try await manager.deduplicated(key: "k") { 5 }

        XCTAssertEqual(value, 5)
        let count = await manager.inFlightCount()
        XCTAssertEqual(count, 0)
    }

    func testThrowingVariant_propagatesError() async {
        let manager = ThrowingInFlightRequestManager<String, Int>()

        do {
            _ = try await manager.deduplicated(key: "k") { throw SampleError.boom }
            XCTFail("expected the operation's error to propagate")
        } catch {
            XCTAssertEqual(error as? SampleError, .boom)
        }

        let count = await manager.inFlightCount()
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Test Helpers

private enum SampleError: Error, Equatable {
    case boom
}

/// Minimal async-safe counter for asserting how many times an operation ran.
private actor AsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// One-shot async gate: `wait()` suspends until `signal()` (or returns
/// immediately if already signaled). Used to hold an operation in flight.
private actor ContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }
}
