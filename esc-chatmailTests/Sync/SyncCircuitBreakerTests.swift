import XCTest
@testable import esc_chatmail

final class SyncCircuitBreakerTests: XCTestCase {

    private var sut: SyncCircuitBreaker!

    override func setUp() async throws {
        try await super.setUp()
        // SyncCircuitBreaker is a singleton; reset before each test to isolate state.
        sut = SyncCircuitBreaker.shared
        await sut.reset()
    }

    override func tearDown() async throws {
        await sut.reset()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState_allowsRequests() async {
        let allowed = await sut.canAttemptSync()
        XCTAssertTrue(allowed)
    }

    func testInitialState_currentStateIsClosed() async {
        let state = await sut.currentState
        guard case .closed = state else {
            return XCTFail("Expected .closed, got \(state)")
        }
    }

    // MARK: - Opening circuit on failures

    func testRecordFailure_belowThreshold_remainsClosed() async {
        for _ in 0..<4 {
            await sut.recordFailure()
        }
        let state = await sut.currentState
        guard case .closed = state else {
            return XCTFail("Expected .closed below threshold, got \(state)")
        }
        let allowed = await sut.canAttemptSync()
        XCTAssertTrue(allowed)
    }

    func testRecordFailure_atThreshold_opensCircuit() async {
        for _ in 0..<5 {
            await sut.recordFailure()
        }
        let state = await sut.currentState
        guard case .open = state else {
            return XCTFail("Expected .open at threshold, got \(state)")
        }
    }

    func testOpenCircuit_blocksSyncAttempts() async {
        for _ in 0..<5 {
            await sut.recordFailure()
        }
        let allowed = await sut.canAttemptSync()
        XCTAssertFalse(allowed, "Open circuit must block new sync attempts")
    }

    // MARK: - Recording success

    func testRecordSuccess_inClosedState_resetsFailureCounter() async {
        // Accumulate some failures (below threshold)
        for _ in 0..<3 {
            await sut.recordFailure()
        }
        await sut.recordSuccess()

        // Now accumulate only enough failures that would have opened before
        for _ in 0..<3 {
            await sut.recordFailure()
        }
        let state = await sut.currentState
        guard case .closed = state else {
            return XCTFail("Success should reset failure count — expected .closed, got \(state)")
        }
    }

    // MARK: - Reset

    func testReset_clearsState() async {
        for _ in 0..<5 {
            await sut.recordFailure()
        }
        await sut.reset()

        let state = await sut.currentState
        guard case .closed = state else {
            return XCTFail("Expected .closed after reset, got \(state)")
        }
        let allowed = await sut.canAttemptSync()
        XCTAssertTrue(allowed)
    }

    // MARK: - isAllowingRequests

    func testIsAllowingRequests_freshCircuit_returnsTrue() async {
        let allowing = await sut.isAllowingRequests
        XCTAssertTrue(allowing)
    }

    func testIsAllowingRequests_openCircuitRecentFailure_returnsFalse() async {
        for _ in 0..<5 {
            await sut.recordFailure()
        }
        let allowing = await sut.isAllowingRequests
        XCTAssertFalse(allowing)
    }
}
