import Foundation

// MARK: - Profile, Labels & Aliases API

extension GmailAPIClient {

    /// Fetches the user's profile.
    nonisolated func getProfile() async throws -> GmailProfile {
        let url = try buildURL(endpoint: APIEndpoints.profile())
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request)
    }

    /// Lists all labels in the mailbox.
    nonisolated func listLabels() async throws -> [GmailLabel] {
        let url = try buildURL(endpoint: APIEndpoints.labels())
        let request = try await authenticatedRequest(url: url)
        let response: LabelsResponse = try await performRequestWithRetry(request)
        return response.labels ?? []
    }

    /// Lists configured send-as aliases.
    nonisolated func listSendAs() async throws -> [SendAs] {
        let url = try buildURL(endpoint: APIEndpoints.sendAs())
        let request = try await authenticatedRequest(url: url)
        let response: SendAsListResponse = try await performRequestWithRetry(request)
        return response.sendAs ?? []
    }
}
