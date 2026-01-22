import Foundation

// MARK: - Profile, Labels & Aliases API

extension GmailAPIClient {

    /// Fetches the user's profile.
    nonisolated func getProfile() async throws -> GmailProfile {
        try await performGET(endpoint: APIEndpoints.profile())
    }

    /// Lists all labels in the mailbox.
    nonisolated func listLabels() async throws -> [GmailLabel] {
        let response: LabelsResponse = try await performGET(endpoint: APIEndpoints.labels())
        return response.labels ?? []
    }

    /// Lists configured send-as aliases.
    nonisolated func listSendAs() async throws -> [SendAs] {
        let response: SendAsListResponse = try await performGET(endpoint: APIEndpoints.sendAs())
        return response.sendAs ?? []
    }
}
