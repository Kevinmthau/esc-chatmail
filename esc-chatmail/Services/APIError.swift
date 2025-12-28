import Foundation

// MARK: - API Errors

enum APIError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case decodingError(Error)
    case authenticationError
    case rateLimited
    case serverError(Int)
    case timeout
    case historyIdExpired
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .authenticationError:
            return "Authentication failed"
        case .rateLimited:
            return "Rate limited by server"
        case .serverError(let code):
            return "Server error: \(code)"
        case .timeout:
            return "Request timed out"
        case .historyIdExpired:
            return "History ID has expired. A full sync is required."
        case .notFound(let resource):
            return "Resource not found: \(resource)"
        }
    }
}

// MARK: - Helper Response Types

/// Empty response for endpoints that don't return data
struct EmptyResponse: Codable {}

/// Gmail API error response structure
struct GmailErrorResponse: Codable {
    let error: GmailErrorDetail

    struct GmailErrorDetail: Codable {
        let code: Int
        let message: String
        let status: String?
    }
}

/// Response type for attachment data
struct AttachmentResponse: Codable {
    let size: Int?
    let data: String
}

// MARK: - Data Extensions for Base64 URL Encoding

extension Data {
    init?(base64UrlEncoded: String) {
        var base64 = base64UrlEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64.append("=")
        }

        self.init(base64Encoded: base64)
    }

    func base64UrlEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Timeout Helper

/// Wraps an async operation with a timeout
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw APIError.timeout
        }

        // Return the first result (either success or timeout)
        guard let result = try await group.next() else {
            throw APIError.timeout
        }
        group.cancelAll()
        return result
    }
}
