import Foundation

// MARK: - People API Client

/// Client for Google People API operations
/// Separated from GmailAPIClient for single responsibility
@MainActor
class PeopleAPIClient {
    static let shared = PeopleAPIClient()

    private let session: URLSession
    private let tokenManager: TokenManagerProtocol

    private init() {
        self.tokenManager = TokenManager.shared

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = max(NetworkConfig.requestTimeout, 30.0)
        configuration.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.session = URLSession(configuration: configuration)
    }

    /// Testable initializer
    init(tokenManager: TokenManagerProtocol) {
        self.tokenManager = tokenManager

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = max(NetworkConfig.requestTimeout, 30.0)
        configuration.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// Search for a person by email address using the Google People API
    nonisolated func searchPeopleByEmail(email: String) async throws -> PeopleSearchResult {
        let endpoint = PeopleAPIEndpoints.searchContacts(query: email)
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }

        let request = try await authenticatedRequest(url: url)
        let response: PeopleSearchResponse = try await performRequest(request)

        return extractBestMatch(from: response, forEmail: email)
    }

    // MARK: - Private Helpers

    private nonisolated func authenticatedRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)

        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }

        let token = try await tokenManager.getCurrentToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private nonisolated func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 401:
                throw APIError.authenticationError
            case 429:
                throw APIError.rateLimited
            case 500...599:
                throw APIError.serverError(httpResponse.statusCode)
            default:
                break
            }
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated func extractBestMatch(from response: PeopleSearchResponse, forEmail email: String) -> PeopleSearchResult {
        guard let results = response.results else {
            return PeopleSearchResult(email: email, displayName: nil, photoURL: nil)
        }

        for result in results {
            guard let person = result.person else { continue }

            // Check if email matches
            let personEmails = person.emailAddresses?.map { $0.value.lowercased() } ?? []
            guard personEmails.contains(email.lowercased()) else { continue }

            // Get the best photo URL
            let photoURL = person.photos?.first(where: { $0.metadata?.primary == true })?.url
                ?? person.photos?.first?.url

            let displayName = person.names?.first?.displayName

            return PeopleSearchResult(
                email: email,
                displayName: displayName,
                photoURL: photoURL
            )
        }

        // No match found
        return PeopleSearchResult(email: email, displayName: nil, photoURL: nil)
    }
}
