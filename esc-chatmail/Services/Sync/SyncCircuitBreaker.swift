import Foundation

/// Circuit breaker pattern for sync operations to prevent repeated failures from wasting resources.
///
/// The circuit breaker has three states:
/// - **Closed**: Normal operation, sync attempts are allowed
/// - **Open**: Too many failures, sync attempts are blocked
/// - **Half-Open**: Testing if the issue is resolved, one sync attempt is allowed
///
/// ## Usage
/// ```swift
/// guard await SyncCircuitBreaker.shared.canAttemptSync() else {
///     Log.debug("Sync circuit breaker is open, skipping sync", category: .sync)
///     return
/// }
///
/// do {
///     try await performSync()
///     await SyncCircuitBreaker.shared.recordSuccess()
/// } catch {
///     await SyncCircuitBreaker.shared.recordFailure()
///     throw error
/// }
/// ```
actor SyncCircuitBreaker {
    static let shared = SyncCircuitBreaker()

    enum State {
        case closed      // Normal operation
        case open        // Blocking requests
        case halfOpen    // Testing if issue resolved
    }

    private var state: State = .closed
    private var failureCount = 0
    private var lastFailureTime: Date?
    private var consecutiveSuccesses = 0

    /// Number of consecutive failures before opening the circuit
    private let failureThreshold = 5

    /// Time in seconds before attempting to close the circuit (5 minutes)
    private let resetTimeout: TimeInterval = 300

    /// Number of consecutive successes needed in half-open state to fully close
    private let successThreshold = 2

    private init() {}

    /// Returns true if a sync attempt should be allowed
    func canAttemptSync() -> Bool {
        switch state {
        case .closed:
            return true

        case .open:
            // Check if enough time has passed to try again
            guard let lastFailure = lastFailureTime else {
                state = .halfOpen
                return true
            }

            let timeSinceLastFailure = Date().timeIntervalSince(lastFailure)
            if timeSinceLastFailure >= resetTimeout {
                state = .halfOpen
                Log.info("Sync circuit breaker transitioning to half-open after \(Int(timeSinceLastFailure))s", category: .sync)
                return true
            }

            Log.debug("Sync circuit breaker is open, \(Int(resetTimeout - timeSinceLastFailure))s until retry", category: .sync)
            return false

        case .halfOpen:
            // Allow one request through to test
            return true
        }
    }

    /// Records a successful sync operation
    func recordSuccess() {
        switch state {
        case .closed:
            failureCount = 0
            consecutiveSuccesses = 0

        case .open:
            // Shouldn't happen, but handle gracefully
            state = .halfOpen
            consecutiveSuccesses = 1

        case .halfOpen:
            consecutiveSuccesses += 1
            if consecutiveSuccesses >= successThreshold {
                state = .closed
                failureCount = 0
                consecutiveSuccesses = 0
                Log.info("Sync circuit breaker closed after \(successThreshold) consecutive successes", category: .sync)
            }
        }
    }

    /// Records a failed sync operation
    func recordFailure() {
        lastFailureTime = Date()
        consecutiveSuccesses = 0

        switch state {
        case .closed:
            failureCount += 1
            if failureCount >= failureThreshold {
                state = .open
                Log.warning("Sync circuit breaker opened after \(failureCount) consecutive failures", category: .sync)
            }

        case .open:
            // Already open, just update the failure time
            break

        case .halfOpen:
            // Failed the test, reopen the circuit
            state = .open
            failureCount = failureThreshold // Reset to threshold to require full timeout
            Log.warning("Sync circuit breaker reopened after test failure", category: .sync)
        }
    }

    /// Manually resets the circuit breaker (e.g., after user action like re-auth)
    func reset() {
        state = .closed
        failureCount = 0
        consecutiveSuccesses = 0
        lastFailureTime = nil
        Log.info("Sync circuit breaker manually reset", category: .sync)
    }

    /// Returns the current state for debugging/monitoring
    var currentState: State {
        state
    }

    /// Returns whether the circuit is currently allowing requests
    var isAllowingRequests: Bool {
        state != .open || (lastFailureTime.map { Date().timeIntervalSince($0) >= resetTimeout } ?? true)
    }
}
