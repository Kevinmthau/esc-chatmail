import Foundation

struct GoogleConfig {
    // Read configuration from Info.plist (which uses xcconfig values)
    private static let bundle = Bundle.main

    private static func requiredConfig(_ key: String) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.contains("$") else {
            fatalError("""
                Missing configuration for \(key).
                Please ensure Debug.xcconfig and Release.xcconfig are properly linked in Xcode.
                See esc-chatmail/Configuration/Config.xcconfig.template for setup instructions.
                """)
        }
        return value
    }

    static let clientId: String = requiredConfig("GOOGLE_CLIENT_ID")
    static let apiKey: String = requiredConfig("GOOGLE_API_KEY")
    static let projectNumber: String = requiredConfig("GOOGLE_PROJECT_NUMBER")
    static let projectId: String = requiredConfig("GOOGLE_PROJECT_ID")
    static let redirectURI: String = requiredConfig("GOOGLE_REDIRECT_URI")

    static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/contacts.other.readonly"
    ]
}

// MARK: - People API Endpoints
struct PeopleAPIEndpoints {
    static let baseURL = "https://people.googleapis.com/v1"

    /// Search for contacts by query (email)
    static func searchContacts(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return "\(baseURL)/otherContacts:search?query=\(encoded)&readMask=photos,names,emailAddresses&pageSize=1"
    }

    /// Get a specific person by resource name
    static func person(resourceName: String) -> String {
        "\(baseURL)/\(resourceName)?personFields=photos,names,emailAddresses"
    }

    /// Search "other contacts" (people you've interacted with)
    static func listOtherContacts() -> String {
        "\(baseURL)/otherContacts?readMask=photos,names,emailAddresses&pageSize=100"
    }
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

    static func sendMessage() -> String {
        "\(baseURL)/users/me/messages/send"
    }
}