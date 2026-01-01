import Foundation

/// Manages in-flight async requests to prevent duplicate operations for the same key.
/// When multiple callers request the same key simultaneously, they all receive the result
/// from a single operation instead of triggering duplicate work.
actor InFlightRequestManager<Key: Hashable & Sendable, Value: Sendable> {

    // MARK: - Properties

    private var inFlightRequests: [Key: Task<Value?, Never>] = [:]
    private var failedKeys: Set<Key> = []
    private let maxFailedKeys: Int

    // MARK: - Initialization

    /// Creates a new request manager
    /// - Parameter maxFailedKeys: Maximum number of failed keys to track (prevents unbounded growth)
    init(maxFailedKeys: Int = 100) {
        self.maxFailedKeys = maxFailedKeys
    }

    // MARK: - Public API

    /// Executes an operation with deduplication.
    /// If a request for the same key is already in progress, waits for and returns that result.
    /// Otherwise, starts a new operation.
    ///
    /// - Parameters:
    ///   - key: The unique identifier for this request
    ///   - operation: The async operation to perform if no request is in flight
    /// - Returns: The result of the operation (may be nil)
    func deduplicated(
        key: Key,
        operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        // If there's already a request in flight, wait for it
        if let existingTask = inFlightRequests[key] {
            return await existingTask.value
        }

        // Start a new request
        let task = Task<Value?, Never> {
            await operation()
        }

        inFlightRequests[key] = task

        let result = await task.value

        // Clean up
        inFlightRequests[key] = nil

        // Track failures
        if result == nil {
            trackFailure(for: key)
        } else {
            failedKeys.remove(key)
        }

        return result
    }

    /// Executes an operation with deduplication, skipping keys that have previously failed.
    /// Useful for avoiding repeated attempts at fetching unavailable resources.
    ///
    /// - Parameters:
    ///   - key: The unique identifier for this request
    ///   - skipIfFailed: Whether to skip keys that have previously failed
    ///   - operation: The async operation to perform
    /// - Returns: The result of the operation (may be nil)
    func deduplicatedWithFailureTracking(
        key: Key,
        skipIfFailed: Bool = true,
        operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        // Skip if this key has previously failed
        if skipIfFailed && failedKeys.contains(key) {
            return nil
        }

        return await deduplicated(key: key, operation: operation)
    }

    /// Checks if a request is currently in progress for the given key
    func isInFlight(_ key: Key) -> Bool {
        inFlightRequests[key] != nil
    }

    /// Returns the number of requests currently in flight
    func inFlightCount() -> Int {
        inFlightRequests.count
    }

    /// Clears the list of failed keys, allowing retry attempts
    func clearFailedKeys() {
        failedKeys.removeAll()
    }

    /// Removes a specific key from the failed list
    func clearFailure(for key: Key) {
        failedKeys.remove(key)
    }

    /// Checks if a key has previously failed
    func hasFailed(_ key: Key) -> Bool {
        failedKeys.contains(key)
    }

    // MARK: - Private Helpers

    private func trackFailure(for key: Key) {
        failedKeys.insert(key)

        // Prevent unbounded growth of failed keys set
        if failedKeys.count > maxFailedKeys {
            // Remove a random key to make room
            if let keyToRemove = failedKeys.first {
                failedKeys.remove(keyToRemove)
            }
        }
    }
}

// MARK: - Throwing Variant

/// A variant of InFlightRequestManager that supports throwing operations
actor ThrowingInFlightRequestManager<Key: Hashable & Sendable, Value: Sendable> {

    private var inFlightRequests: [Key: Task<Value, Error>] = [:]

    /// Executes a throwing operation with deduplication.
    func deduplicated(
        key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        // If there's already a request in flight, wait for it
        if let existingTask = inFlightRequests[key] {
            return try await existingTask.value
        }

        // Start a new request
        let task = Task<Value, Error> {
            try await operation()
        }

        inFlightRequests[key] = task

        defer {
            inFlightRequests[key] = nil
        }

        return try await task.value
    }

    /// Checks if a request is currently in progress for the given key
    func isInFlight(_ key: Key) -> Bool {
        inFlightRequests[key] != nil
    }

    /// Returns the number of requests currently in flight
    func inFlightCount() -> Int {
        inFlightRequests.count
    }
}
