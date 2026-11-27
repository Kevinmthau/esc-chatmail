import Foundation
@testable import esc_chatmail

/// Mock implementation of TokenRefresherProtocol for TokenManager tests.
/// Allows injecting access/refresh tokens and failure modes without touching Google Sign-In.
final class MockTokenRefresher: TokenRefresherProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var _accessToken: String = "refreshed-access-token"
    private var _refreshToken: String? = "refreshed-refresh-token"
    private var _expirationDate: Date = Date().addingTimeInterval(3600)
    private var _error: Error?
    private var _callCount: Int = 0
    private var _artificialDelay: TimeInterval = 0

    var accessToken: String {
        get { lock.withLock { _accessToken } }
        set { lock.withLock { _accessToken = newValue } }
    }

    var refreshToken: String? {
        get { lock.withLock { _refreshToken } }
        set { lock.withLock { _refreshToken = newValue } }
    }

    var expirationDate: Date {
        get { lock.withLock { _expirationDate } }
        set { lock.withLock { _expirationDate = newValue } }
    }

    var errorToThrow: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    var artificialDelay: TimeInterval {
        get { lock.withLock { _artificialDelay } }
        set { lock.withLock { _artificialDelay = newValue } }
    }

    /// Fires after the refreshed tokens are produced but before they are
    /// returned to the caller, letting a test emulate an event (e.g.
    /// sign-out) landing mid-refresh — after the caller snapshotted its
    /// generation, before it persists the result. Runs outside the mock's
    /// lock so the hook may re-enter the token manager.
    private var _onRefresh: (() -> Void)?
    var onRefresh: (() -> Void)? {
        get { lock.withLock { _onRefresh } }
        set { lock.withLock { _onRefresh = newValue } }
    }

    // MARK: - Forced refresh (`forceRefreshTokens`)

    private var _forcedAccessToken: String = "forced-access-token"
    private var _forcedError: Error?
    private var _forcedCallCount: Int = 0
    private var _onForcedRefresh: (() -> Void)?
    private var _forcedRefreshGate: (@Sendable () async -> Void)?

    /// What a forced refresh returns, with `refreshToken` and `expirationDate`.
    var forcedAccessToken: String {
        get { lock.withLock { _forcedAccessToken } }
        set { lock.withLock { _forcedAccessToken = newValue } }
    }

    var forcedErrorToThrow: Error? {
        get { lock.withLock { _forcedError } }
        set { lock.withLock { _forcedError = newValue } }
    }

    /// Forced refreshes only; `callCount` counts the plain ones.
    var forcedCallCount: Int {
        lock.withLock { _forcedCallCount }
    }

    /// As `onRefresh`, for a forced refresh: after its tokens are produced,
    /// before they are returned.
    var onForcedRefresh: (() -> Void)? {
        get { lock.withLock { _onForcedRefresh } }
        set { lock.withLock { _onForcedRefresh = newValue } }
    }

    /// Awaited after a forced refresh is counted and before it answers: holds
    /// it open until the test's condition (deadline-bounded by the test).
    var forcedRefreshGate: (@Sendable () async -> Void)? {
        get { lock.withLock { _forcedRefreshGate } }
        set { lock.withLock { _forcedRefreshGate = newValue } }
    }

    func forceRefreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        let gate: (@Sendable () async -> Void)? = lock.withLock {
            _forcedCallCount += 1
            return _forcedRefreshGate
        }
        if let gate {
            await gate()
        }

        let result: (accessToken: String, refreshToken: String?, expirationDate: Date) = try lock.withLock {
            if let error = _forcedError {
                throw error
            }
            return (_forcedAccessToken, _refreshToken, _expirationDate)
        }

        onForcedRefresh?()
        return result
    }

    func refreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        let delay = artificialDelay
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        let result: (accessToken: String, refreshToken: String?, expirationDate: Date) = try lock.withLock {
            _callCount += 1
            if let error = _error {
                throw error
            }
            return (_accessToken, _refreshToken, _expirationDate)
        }

        onRefresh?()
        return result
    }
}
