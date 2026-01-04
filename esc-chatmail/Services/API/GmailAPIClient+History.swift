import Foundation

// MARK: - History API

extension GmailAPIClient {

    /// Lists history changes since a given history ID.
    nonisolated func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> HistoryResponse {
        let endpoint = APIEndpoints.history()
        guard var components = URLComponents(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId)
        ]
        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        guard let url = components.url else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)

        // Use specialized error handling for history API
        return try await performHistoryRequest(request)
    }

    /// Specialized request handler for history API that detects expired history IDs.
    func performHistoryRequest(_ request: URLRequest) async throws -> HistoryResponse {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(HistoryResponse.self, from: data)

        case 404:
            // Gmail returns 404 when historyId is expired or invalid
            if let errorResponse = try? JSONDecoder().decode(GmailErrorResponse.self, from: data) {
                let errorMessage = errorResponse.error.message.lowercased()
                if errorMessage.contains("not found") ||
                   errorMessage.contains("invalid") ||
                   errorMessage.contains("too old") {
                    Log.warning("History ID expired: \(errorResponse.error.message)", category: .api)
                    throw APIError.historyIdExpired
                }
            }
            throw APIError.historyIdExpired

        case 401:
            throw APIError.authenticationError

        case 429:
            throw APIError.rateLimited

        case 500...599:
            throw APIError.serverError(httpResponse.statusCode)

        default:
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}
