import Foundation

// MARK: - Async Convenience Wrappers
extension TokenManager {
    nonisolated func withValidToken<T>(_ operation: @escaping (String) async throws -> T) async throws -> T {
        let token = try await getCurrentToken()
        return try await operation(token)
    }

    nonisolated func withTokenRetry<T>(_ operation: @escaping (String) async throws -> T) async throws -> T {
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

    func isAuthError(_ error: Error) -> Bool {
        // Check if error is authentication related
        let nsError = error as NSError
        let authErrorCodes = [401, 403] // Unauthorized, Forbidden

        if let urlError = error as? URLError {
            return urlError.code == .userAuthenticationRequired
        }

        return authErrorCodes.contains(nsError.code)
    }
}
