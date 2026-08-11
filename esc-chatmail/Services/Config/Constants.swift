import Foundation

struct GoogleConfig {
    // Read configuration from Info.plist (which uses xcconfig values)
    private static let bundle = Bundle.main

    /// Error thrown when required configuration is missing
    enum ConfigurationError: LocalizedError {
        case missingKey(String)

        var errorDescription: String? {
            switch self {
            case .missingKey(let key):
                return """
                    Missing configuration for \(key).
                    Please ensure Debug.xcconfig and Release.xcconfig are properly linked in Xcode.
                    See esc-chatmail/Configuration/Config.xcconfig.template for setup instructions.
                    """
            }
        }
    }

    private static func optionalConfig(_ key: String) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.contains("$") else {
            return nil
        }
        return value
    }

    private static func requiredConfig(_ key: String) -> String {
        guard let value = optionalConfig(key) else {
            #if DEBUG
            fatalError(ConfigurationError.missingKey(key).localizedDescription)
            #else
            Log.error("Missing required configuration: \(key)", category: .auth)
            return ""
            #endif
        }
        return value
    }

    /// Indicates whether all required Google configuration is present
    static var isConfigured: Bool {
        return optionalConfig("GOOGLE_CLIENT_ID") != nil &&
               optionalConfig("GOOGLE_API_KEY") != nil &&
               optionalConfig("GOOGLE_PROJECT_NUMBER") != nil &&
               optionalConfig("GOOGLE_PROJECT_ID") != nil &&
               optionalConfig("GOOGLE_REDIRECT_URI") != nil
    }

    /// Returns a list of missing configuration keys (for error display)
    static var missingKeys: [String] {
        var missing: [String] = []
        if optionalConfig("GOOGLE_CLIENT_ID") == nil { missing.append("GOOGLE_CLIENT_ID") }
        if optionalConfig("GOOGLE_API_KEY") == nil { missing.append("GOOGLE_API_KEY") }
        if optionalConfig("GOOGLE_PROJECT_NUMBER") == nil { missing.append("GOOGLE_PROJECT_NUMBER") }
        if optionalConfig("GOOGLE_PROJECT_ID") == nil { missing.append("GOOGLE_PROJECT_ID") }
        if optionalConfig("GOOGLE_REDIRECT_URI") == nil { missing.append("GOOGLE_REDIRECT_URI") }
        return missing
    }

    static let clientId: String = requiredConfig("GOOGLE_CLIENT_ID")
    static let apiKey: String = requiredConfig("GOOGLE_API_KEY")
    static let projectNumber: String = requiredConfig("GOOGLE_PROJECT_NUMBER")
    static let projectId: String = requiredConfig("GOOGLE_PROJECT_ID")
    static let redirectURI: String = requiredConfig("GOOGLE_REDIRECT_URI")

    /// Base OIDC scopes granted during sign-in.
    static let baseScopes = [
        "openid",
        "email",
        "profile"
    ]

    /// Gmail API scope required for sync and message actions.
    static let gmailModifyScope = "https://www.googleapis.com/auth/gmail.modify"

    /// Scopes requested in addition to base profile scopes.
    static let additionalScopes = [gmailModifyScope]

    /// Full scope set tracked in token metadata.
    static let scopes = baseScopes + additionalScopes
}

// MARK: - Sync Configuration
struct SyncConfig {
    /// Number of messages to process in each batch during sync
    static let messageBatchSize = 50

    /// Maximum messages to fetch per API call
    static let maxMessagesPerRequest = 500

    /// Maximum history records requested from Gmail per page.
    static let maxHistoryResultsPerRequest = 500

    /// Maximum history pages retained in memory for one foreground slice.
    /// At Gmail's 500-record page limit this preserves the old ~5,000-record
    /// bound while model-v3 checkpoints carry larger backlogs across runs.
    static let maxHistoryPagesPerForegroundSlice = 10

    /// Maximum concurrent message fetch requests to prevent resource exhaustion
    static let maxConcurrentMessageFetches = 15

    /// Maximum concurrent message *processing* operations (HTML/text extraction,
    /// classification, large-body fetches). Processing is largely CPU-bound, so this
    /// is capped near the core count to parallelize without thrashing. Persistence of
    /// the processed result remains serialized to preserve conversation-routing order.
    static let maxConcurrentMessageProcessing = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 6))

    /// Delay before retrying failed message fetches (in seconds)
    static let retryDelaySeconds: UInt64 = 1_000_000_000

    /// Timeout for individual message fetch operations (in seconds)
    static let messageFetchTimeout: TimeInterval = 15.0

    /// Timeout for batch operations (in seconds)
    static let batchOperationTimeout: TimeInterval = 60.0

    /// Maximum number of consecutive sync failures before advancing historyId anyway
    /// This prevents sync from getting permanently stuck on unfetchable messages
    static let maxConsecutiveSyncFailures = 3

    /// Maximum number of retry attempts for an abandoned message before giving up on it
    static let maxAbandonedMessageRetries = 5

    /// Maximum number of abandoned messages drained (one attempt each) per incremental sync
    static let maxAbandonedMessagesPerSync = 50

    /// Base drain backoff after an abandoned message's first failed retry (15 minutes)
    static let abandonedRetryBackoffBase: TimeInterval = 900

    /// Ceiling on the drain backoff between abandoned-message retries (12 hours)
    static let abandonedRetryBackoffCap: TimeInterval = 43_200

    /// UserDefaults key for tracking consecutive sync failures
    static let consecutiveFailuresKey = "syncConsecutiveFailures"

    /// UserDefaults key for tracking failed message IDs across syncs
    static let persistentFailedIdsKey = "syncPersistentFailedIds"

    /// UserDefaults key for tracking last successful sync time
    static let lastSuccessfulSyncTimeKey = "lastSuccessfulSyncTime"

    /// UserDefaults key for tracking last label reconciliation time
    static let lastReconciliationTimeKey = "lastReconciliationTime"

    /// UserDefaults key marking that legacy AbandonedSyncMessage retryCounts were reset.
    /// Before the retry drain existed, retryCount counted re-abandonments; the drain
    /// counts actual retry attempts, so legacy values must not consume its budget.
    static let abandonedRetryCountResetKey = "abandonedRetryCountReset"

    /// UserDefaults key for resuming bounded missed-message reconciliation windows
    static let missedMessageReconciliationCursorKey = "missedMessageReconciliationCursor"

    /// Interval between forced label reconciliations even when history is empty (in seconds)
    /// Running reconciliation hourly ensures label drift is caught even without history changes
    static let reconciliationInterval: TimeInterval = 3600 // 1 hour

    /// Minimum interval between label reconciliations when history DID report
    /// changes (in seconds). Label reconciliation costs one list call plus one
    /// metadata GET per recent message (up to ~100 at 10-way concurrency), so
    /// running it on every push-triggered sync dominates steady-state quota
    /// usage and feeds 429s. Label drift repair tolerates this latency.
    static let labelReconciliationTTL: TimeInterval = 20 * 60 // 20 minutes

    // MARK: - Time Buffer Constants

    /// Buffer subtracted from timestamps to ensure we don't miss messages due to clock drift (5 minutes)
    static let timestampBufferSeconds: TimeInterval = 300

    /// Larger buffer for recovery operations where we want extra safety margin (10 minutes)
    static let recoveryBufferSeconds: TimeInterval = 600

    /// Maximum age for local modifications before server updates are allowed (30 minutes)
    /// Prevents indefinite blocking of server sync while protecting recent local changes
    static let maxLocalModificationAge: TimeInterval = 1800

    /// Maximum reconciliation window to prevent excessive API calls (24 hours)
    static let maxReconciliationWindow: TimeInterval = 86400

    /// Number of recent messages to request per reconciliation page
    static let reconciliationPageSize = 100

    /// Minimum number of recent messages to inspect during reconciliation
    static let minimumReconciliationMessages = 100

    /// Maximum number of recent messages to inspect during reconciliation
    static let maxReconciliationMessages = 500

    /// Fallback window when no sync history exists - initial sync (30 days)
    static let initialSyncFallbackWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Fallback window for history recovery sync (7 days)
    static let recoveryFallbackWindow: TimeInterval = 7 * 24 * 60 * 60
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

    /// Maximum total time for all retry attempts (circuit breaker)
    /// Prevents indefinite waiting on repeated failures
    static let maxTotalRetryTime: TimeInterval = 120.0

    /// Maximum allowed Retry-After header value (in seconds)
    /// Prevents honoring excessively long server-requested delays
    static let maxRetryAfterSeconds: TimeInterval = 60.0
}

// MARK: - UI Configuration
struct UIConfig {
    /// Delay for initial scroll after view appears (in seconds)
    static let initialScrollDelay: TimeInterval = 0.15

    /// Delay for scroll after content changes (in seconds)
    static let contentChangeScrollDelay: TimeInterval = 0.05

    /// Duration of scroll animations (in seconds)
    static let scrollAnimationDuration: TimeInterval = 0.2
}

// MARK: - Cache Configuration
struct CacheConfig {
    /// Maximum items in processed text cache
    static let textCacheSize = 500

    /// Maximum memory in bytes for processed text cache (5 MB)
    static let textCacheMaxBytes = 5 * 1024 * 1024

    /// Maximum items in profile photo cache
    static let photoCacheSize = 500

    /// Maximum items in HTML content cache
    static let htmlCacheSize = 1000

    /// Maximum items in conversation cache
    static let conversationCacheSize = 100

    /// Time-to-live for cached profile photos (24 hours)
    static let photoCacheTTL: TimeInterval = 86400

    /// Time-to-live for conversation cache entries (5 minutes)
    static let conversationCacheTTL: TimeInterval = 300

    /// Time-to-live for disk image cache (7 days)
    static let diskImageCacheTTL: TimeInterval = 604800

    /// Maximum disk cache size in bytes (100 MB)
    static let maxDiskCacheSize: Int = 100 * 1024 * 1024

    /// Maximum memory cache size for thumbnails in bytes (50 MB)
    static let maxThumbnailCacheSize: Int = 50 * 1024 * 1024

    /// Maximum memory cache size for full images in bytes (100 MB)
    static let maxFullImageCacheSize: Int = 100 * 1024 * 1024
}

// MARK: - Attachment Configuration
struct AttachmentConfig {
    /// Maximum byte size for signature images (10 KB)
    static let signatureImageMaxBytes: Int64 = 10 * 1024

    /// Maximum dimension for signature images (100 pixels)
    static let signatureImageMaxDimension: Int16 = 100
}

// MARK: - Cleanup Intervals
/// Centralized cleanup intervals for periodic maintenance tasks
struct CleanupIntervals {
    /// Disk image cache cleanup interval (1 hour)
    static let diskImageCache: TimeInterval = 3600

    /// Person cache cleanup interval (5 minutes)
    static let personCache: TimeInterval = 300

    /// Disk files cache cleanup interval (24 hours)
    static let diskFilesCache: TimeInterval = 86400
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
