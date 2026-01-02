import Foundation

/// A reusable exponential backoff calculator for retry logic.
/// Thread-safe when wrapped in an actor.
public struct ExponentialBackoff: Sendable {
    private var attempt = 0
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let factor: Double
    private let jitter: Double

    /// Creates an exponential backoff calculator.
    /// - Parameters:
    ///   - baseDelay: The initial delay (default: 1.0 second)
    ///   - maxDelay: Maximum delay cap (default: 60.0 seconds)
    ///   - factor: Multiplication factor per attempt (default: 2.0)
    ///   - jitter: Random jitter percentage to avoid thundering herd (default: 0.1 = 10%)
    public init(
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        factor: Double = 2.0,
        jitter: Double = 0.1
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.factor = factor
        self.jitter = jitter
    }

    /// Calculates the next delay and increments the attempt counter.
    /// - Returns: The delay in seconds for the current attempt
    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }

        let exponentialDelay = min(baseDelay * pow(factor, Double(attempt)), maxDelay)
        let jitterAmount = exponentialDelay * jitter * Double.random(in: -1...1)

        return exponentialDelay + jitterAmount
    }

    /// Resets the attempt counter to zero.
    public mutating func reset() {
        attempt = 0
    }

    /// Returns the current attempt number (0-indexed).
    public var currentAttempt: Int {
        attempt
    }
}

/// Actor wrapper for thread-safe exponential backoff usage.
public actor ExponentialBackoffActor {
    private var backoff: ExponentialBackoff

    public init(
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        factor: Double = 2.0,
        jitter: Double = 0.1
    ) {
        self.backoff = ExponentialBackoff(
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            factor: factor,
            jitter: jitter
        )
    }

    public func nextDelay() -> TimeInterval {
        backoff.nextDelay()
    }

    public func reset() {
        backoff.reset()
    }

    public var currentAttempt: Int {
        backoff.currentAttempt
    }
}
