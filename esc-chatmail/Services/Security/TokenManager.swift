import Foundation
import GoogleSignIn
import Combine

// MARK: - Token Manager Error
enum TokenManagerError: LocalizedError {
    case noValidToken
    case refreshFailed(Error)
    case networkUnavailable
    case rateLimitExceeded
    case invalidCredentials
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .noValidToken:
            return "No valid authentication token available"
        case .refreshFailed(let error):
            return "Failed to refresh token: \(error.localizedDescription)"
        case .networkUnavailable:
            return "Network connection unavailable"
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later"
        case .invalidCredentials:
            return "Invalid credentials. Please sign in again"
        case .tokenExpired:
            return "Authentication token has expired"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noValidToken, .invalidCredentials, .tokenExpired:
            return "Please sign in again to continue"
        case .refreshFailed:
            return "Check your internet connection and try again"
        case .networkUnavailable:
            return "Please check your internet connection"
        case .rateLimitExceeded:
            return "Wait a few minutes before trying again"
        }
    }
}

// MARK: - Token Info
struct TokenInfo: Codable {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
    let scope: String?

    var isExpired: Bool {
        Date() >= expirationDate
    }

    var isExpiringSoon: Bool {
        // Consider token expiring soon if less than 5 minutes remain
        Date().addingTimeInterval(300) >= expirationDate
    }
}

// MARK: - Token Manager Protocol
protocol TokenManagerProtocol {
    func getCurrentToken() async throws -> String
    func refreshToken() async throws -> String
    func saveTokens(access: String, refresh: String?, expirationDate: Date) throws
    func clearTokens() throws
    func isAuthenticated() -> Bool
}

// MARK: - Token Manager Implementation
final class TokenManager: ObservableObject, TokenManagerProtocol {
    static let shared = TokenManager()

    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: Error?

    private let keychainService: KeychainServiceProtocol
    private let authSession: AuthSession
    private var refreshTask: Task<String, Error>?
    private let refreshQueue = DispatchQueue(label: "com.esc.tokenmanager.refresh")
    private var refreshBackoff = ExponentialBackoff()

    // Token refresh configuration
    private let maxRetryAttempts = 3
    private let baseRetryDelay: TimeInterval = 1.0

    // MARK: - Initialization
    init(keychainService: KeychainServiceProtocol = KeychainService.shared,
         authSession: AuthSession = .shared) {
        self.keychainService = keychainService
        self.authSession = authSession
    }

    // MARK: - Public Methods

    func getCurrentToken() async throws -> String {
        // First, try to get token from memory (AuthSession)
        if let memoryToken = authSession.accessToken {
            // Verify it's still valid
            if let tokenInfo = try? loadTokenInfo(), !tokenInfo.isExpiringSoon {
                return memoryToken
            }
        }

        // Try to load from keychain
        if let tokenInfo = try? loadTokenInfo(), !tokenInfo.isExpiringSoon {
            // Update memory cache
            await MainActor.run {
                authSession.accessToken = tokenInfo.accessToken
            }
            return tokenInfo.accessToken
        }

        // Token is expired or expiring soon, refresh it
        return try await refreshToken()
    }

    func refreshToken() async throws -> String {
        // Prevent multiple simultaneous refresh attempts
        if let existingTask = refreshTask {
            return try await existingTask.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self = self else {
                throw TokenManagerError.noValidToken
            }

            await MainActor.run {
                self.isRefreshing = true
                self.lastRefreshError = nil
            }

            defer {
                Task { @MainActor in
                    self.isRefreshing = false
                    self.refreshTask = nil
                }
            }

            return try await self.performTokenRefresh()
        }

        refreshTask = task
        return try await task.value
    }

    func saveTokens(access: String, refresh: String?, expirationDate: Date) throws {
        let tokenInfo = TokenInfo(
            accessToken: access,
            refreshToken: refresh,
            expirationDate: expirationDate,
            scope: GoogleConfig.scopes.joined(separator: " ")
        )

        // Save to keychain
        try keychainService.saveCodable(tokenInfo, for: KeychainService.Key.googleAccessToken.rawValue, withAccess: .whenUnlockedThisDeviceOnly)

        if let refresh = refresh {
            try keychainService.saveString(refresh, for: KeychainService.Key.googleRefreshToken.rawValue, withAccess: .whenUnlockedThisDeviceOnly)
        }

        // Update memory cache
        Task { @MainActor in
            authSession.accessToken = access
        }

        // Reset backoff on successful save
        refreshBackoff.reset()
    }

    func clearTokens() throws {
        // Clear from keychain
        try keychainService.delete(for: KeychainService.Key.googleAccessToken.rawValue)
        try keychainService.delete(for: KeychainService.Key.googleRefreshToken.rawValue)

        // Clear from memory
        Task { @MainActor in
            authSession.accessToken = nil
        }
    }

    func isAuthenticated() -> Bool {
        // Check if we have valid tokens
        if let tokenInfo = try? loadTokenInfo() {
            return !tokenInfo.isExpired
        }
        return false
    }

    // MARK: - Private Methods

    private func performTokenRefresh() async throws -> String {
        var lastError: Error?

        for attempt in 0..<maxRetryAttempts {
            do {
                // Use exponential backoff for retries
                if attempt > 0 {
                    let delay = refreshBackoff.nextDelay()
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                // Attempt to refresh using Google Sign-In
                let newToken = try await refreshUsingGoogleSignIn()
                refreshBackoff.reset()
                return newToken

            } catch let error {
                lastError = error

                // Check if error is retryable
                if !isRetryableError(error) {
                    await MainActor.run {
                        self.lastRefreshError = error
                    }
                    throw error
                }

                // Log retry attempt
                print("Token refresh attempt \(attempt + 1) failed: \(error)")
            }
        }

        // All retries failed
        let finalError = lastError ?? TokenManagerError.refreshFailed(NSError(domain: "TokenManager", code: -1))
        await MainActor.run {
            self.lastRefreshError = finalError
        }
        throw finalError
    }

    private func refreshUsingGoogleSignIn() async throws -> String {
        guard let user = authSession.currentUser else {
            throw TokenManagerError.noValidToken
        }

        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { tokens, error in
                if let error = error {
                    continuation.resume(throwing: TokenManagerError.refreshFailed(error))
                } else if let tokens = tokens {
                    // Save the new tokens
                    do {
                        try self.saveTokens(
                            access: tokens.accessToken.tokenString,
                            refresh: tokens.refreshToken.tokenString,
                            expirationDate: tokens.accessToken.expirationDate ?? Date().addingTimeInterval(3600)
                        )
                        continuation.resume(returning: tokens.accessToken.tokenString)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: TokenManagerError.noValidToken)
                }
            }
        }
    }

    private func loadTokenInfo() throws -> TokenInfo {
        return try keychainService.loadCodable(TokenInfo.self, for: KeychainService.Key.googleAccessToken.rawValue)
    }

    private func isRetryableError(_ error: Error) -> Bool {
        // Determine if the error is retryable
        if let tokenError = error as? TokenManagerError {
            switch tokenError {
            case .networkUnavailable, .rateLimitExceeded:
                return true
            case .noValidToken, .invalidCredentials, .tokenExpired:
                return false
            case .refreshFailed:
                return true // Could be transient
            }
        }

        // Check for network errors
        let nsError = error as NSError
        let networkErrorCodes = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost
        ]

        return networkErrorCodes.contains(nsError.code)
    }
}

// MARK: - Exponential Backoff
private struct ExponentialBackoff {
    private var attempt = 0
    private let baseDelay: TimeInterval = 1.0
    private let maxDelay: TimeInterval = 60.0
    private let factor: Double = 2.0
    private let jitter: Double = 0.1

    mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }

        let exponentialDelay = min(baseDelay * pow(factor, Double(attempt)), maxDelay)
        let jitterAmount = exponentialDelay * jitter * Double.random(in: -1...1)

        return exponentialDelay + jitterAmount
    }

    mutating func reset() {
        attempt = 0
    }
}

// MARK: - Token Manager + Async Extensions
extension TokenManager {
    func withValidToken<T>(_ operation: @escaping (String) async throws -> T) async throws -> T {
        let token = try await getCurrentToken()
        return try await operation(token)
    }

    func withTokenRetry<T>(_ operation: @escaping (String) async throws -> T) async throws -> T {
        do {
            let token = try await getCurrentToken()
            return try await operation(token)
        } catch {
            // If operation failed, try refreshing token once and retry
            if isAuthError(error) {
                let newToken = try await refreshToken()
                return try await operation(newToken)
            }
            throw error
        }
    }

    private func isAuthError(_ error: Error) -> Bool {
        // Check if error is authentication related
        let nsError = error as NSError
        let authErrorCodes = [401, 403] // Unauthorized, Forbidden

        if let urlError = error as? URLError {
            return urlError.code == .userAuthenticationRequired
        }

        return authErrorCodes.contains(nsError.code)
    }
}