import Foundation

// MARK: - Profile, Labels & Aliases API

extension GmailAPIClient {

    /// Fetches the user's profile.
    nonisolated func getProfile() async throws -> GmailProfile {
        guard let url = URL(string: APIEndpoints.profile()) else {
            throw APIError.invalidURL(APIEndpoints.profile())
        }
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request)
    }

    /// Lists all labels in the mailbox.
    nonisolated func listLabels() async throws -> [GmailLabel] {
        guard let url = URL(string: APIEndpoints.labels()) else {
            throw APIError.invalidURL(APIEndpoints.labels())
        }
        let request = try await authenticatedRequest(url: url)
        let response: LabelsResponse = try await performRequestWithRetry(request)
        return response.labels ?? []
    }

    /// Lists configured send-as aliases.
    nonisolated func listSendAs() async throws -> [SendAs] {
        let endpoint = APIEndpoints.sendAs()
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)
        let response: SendAsListResponse = try await performRequestWithRetry(request)
        return response.sendAs ?? []
    }
}
