import Foundation

struct GoogleConfig {
    // Read configuration from Info.plist (which uses xcconfig values)
    private static let bundle = Bundle.main
    private static let infoDictionary = bundle.infoDictionary ?? [:]

    static func printConfigurationStatus() {
        #if DEBUG
        print("📋 Configuration Status:")
        print("  GOOGLE_CLIENT_ID from plist: \(bundle.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") ?? "nil")")
        print("  Using fallback values: \(!clientId.isEmpty)")
        print("  Note: To use xcconfig files, link them in Xcode project settings")
        #endif
    }

    static let clientId: String = {
        guard let clientId = bundle.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
              !clientId.isEmpty,
              !clientId.contains("$") else {  // Check if it's still a variable like $(GOOGLE_CLIENT_ID)
            // Use the actual value temporarily until xcconfig is properly linked
            return "999923476073-b4m4r3o96gv30rqmo71qo210oa46au74.apps.googleusercontent.com"
        }
        return clientId
    }()

    static let apiKey: String = {
        guard let apiKey = bundle.object(forInfoDictionaryKey: "GOOGLE_API_KEY") as? String,
              !apiKey.isEmpty,
              !apiKey.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "AIzaSyAnVWdfhCGB0raSuwStoMl6U3368E9-gxk"
        }
        return apiKey
    }()

    static let projectNumber: String = {
        guard let projectNumber = bundle.object(forInfoDictionaryKey: "GOOGLE_PROJECT_NUMBER") as? String,
              !projectNumber.isEmpty,
              !projectNumber.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "999923476073"
        }
        return projectNumber
    }()

    static let projectId: String = {
        guard let projectId = bundle.object(forInfoDictionaryKey: "GOOGLE_PROJECT_ID") as? String,
              !projectId.isEmpty,
              !projectId.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "esc-gmail-client"
        }
        return projectId
    }()

    static let redirectURI: String = {
        guard let redirectURI = bundle.object(forInfoDictionaryKey: "GOOGLE_REDIRECT_URI") as? String,
              !redirectURI.isEmpty,
              !redirectURI.contains("$") else {
            // Use the actual value temporarily until xcconfig is properly linked
            return "com.googleusercontent.apps.999923476073-b4m4r3o96gv30rqmo71qo210oa46au74"
        }
        return redirectURI
    }()

    static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.modify"
    ]
}

// MARK: - Sync Configuration
struct SyncConfig {
    /// Number of messages to process in each batch during sync
    static let messageBatchSize = 50

    /// Maximum messages to fetch per API call
    static let maxMessagesPerRequest = 500

    /// Delay before retrying failed message fetches (in seconds)
    static let retryDelaySeconds: UInt64 = 1_000_000_000

    /// Timeout for individual message fetch operations (in seconds)
    static let messageFetchTimeout: TimeInterval = 15.0

    /// Timeout for batch operations (in seconds)
    static let batchOperationTimeout: TimeInterval = 60.0
}

// MARK: - Core Data Configuration
struct CoreDataConfig {
    /// Number of items to fetch per batch for UI lists
    static let fetchBatchSize = 30

    /// Maximum retry attempts for store loading
    static let maxLoadAttempts = 3

    /// Delay between store load retries (in seconds)
    static let retryDelay: TimeInterval = 2.0

    /// Maximum retry attempts for save operations
    static let maxSaveRetries = 3
}

// MARK: - Network Configuration
struct NetworkConfig {
    /// Request timeout interval (in seconds)
    static let requestTimeout: TimeInterval = 30.0

    /// Resource timeout interval (in seconds)
    static let resourceTimeout: TimeInterval = 60.0

    /// Maximum retry attempts for API requests
    static let maxRetries = 3

    /// Initial retry delay (in seconds)
    static let initialRetryDelay: TimeInterval = 1.0

    /// Maximum retry delay cap (in seconds)
    static let maxRetryDelay: TimeInterval = 30.0
}

// MARK: - UI Configuration
struct UIConfig {
    /// Delay for initial scroll after view appears (in seconds)
    static let initialScrollDelay: TimeInterval = 0.3

    /// Delay for scroll after content changes (in seconds)
    static let contentChangeScrollDelay: TimeInterval = 0.1

    /// Duration of scroll animations (in seconds)
    static let scrollAnimationDuration: TimeInterval = 0.25
}

struct APIEndpoints {
    static let baseURL = "https://gmail.googleapis.com/gmail/v1"
    
    static func profile() -> String {
        "\(baseURL)/users/me/profile"
    }
    
    static func labels() -> String {
        "\(baseURL)/users/me/labels"
    }
    
    static func messages() -> String {
        "\(baseURL)/users/me/messages"
    }
    
    static func message(id: String) -> String {
        "\(baseURL)/users/me/messages/\(id)"
    }
    
    static func modifyMessage(id: String) -> String {
        "\(baseURL)/users/me/messages/\(id)/modify"
    }
    
    static func batchModify() -> String {
        "\(baseURL)/users/me/messages/batchModify"
    }
    
    static func history() -> String {
        "\(baseURL)/users/me/history"
    }
    
    static func sendAs() -> String {
        "\(baseURL)/users/me/settings/sendAs"
    }
    
    static func attachment(messageId: String, attachmentId: String) -> String {
        "\(baseURL)/users/me/messages/\(messageId)/attachments/\(attachmentId)"
    }
}