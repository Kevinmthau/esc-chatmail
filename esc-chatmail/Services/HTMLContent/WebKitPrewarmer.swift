import WebKit
import Contacts

/// Pre-warms expensive subsystems to avoid freezes on first use.
///
/// Warms up:
/// - WebKit processes (WebContent, GPU, Networking) - ~3 seconds on first WKWebView
/// - OAuth token refresh - ~10 seconds on first API call after app launch
/// - Contacts framework - ~1 second on first CNContactStore access
///
/// Call early in app lifecycle (e.g., ConversationListView.onAppear).
enum AppPrewarmer {
    private static var hasPrewarmedWebKit = false
    private static var hasPrewarmedAPI = false
    private static var hasPrewarmedContacts = false

    /// Pre-warms all subsystems. Safe to call multiple times.
    @MainActor
    static func prewarmAll() {
        prewarmWebKitIfNeeded()
        prewarmAPIIfNeeded()
        prewarmContactsIfNeeded()
    }

    /// Pre-warms WebKit processes
    @MainActor
    static func prewarmWebKitIfNeeded() {
        guard !hasPrewarmedWebKit else { return }
        hasPrewarmedWebKit = true

        // Create a minimal WebView to trigger process launches
        Task.detached(priority: .utility) {
            await MainActor.run {
                let webView = WKWebView(frame: .zero)
                webView.loadHTMLString("<html></html>", baseURL: nil)
                // WebView will be deallocated, but processes stay running
            }
        }
    }

    /// Pre-warms OAuth token and API connection
    @MainActor
    static func prewarmAPIIfNeeded() {
        guard !hasPrewarmedAPI else { return }
        hasPrewarmedAPI = true

        // Trigger token refresh in background - this warms up:
        // 1. Google Sign-In SDK initialization
        // 2. OAuth token refresh network call
        // 3. URLSession connection pool
        Task.detached(priority: .utility) {
            do {
                _ = try await TokenManager.shared.getCurrentToken()
            } catch {
                // Token prewarm failed - sync will handle refresh later
                Log.debug("API prewarm: token refresh deferred", category: .auth)
            }
        }
    }

    /// Pre-warms Contacts framework for compose view
    @MainActor
    static func prewarmContactsIfNeeded() {
        guard !hasPrewarmedContacts else { return }
        hasPrewarmedContacts = true

        // Initialize CNContactStore and check authorization in background
        // This warms up the Contacts framework before compose view opens
        Task.detached(priority: .utility) {
            let store = CNContactStore()
            _ = CNContactStore.authorizationStatus(for: .contacts)

            // Make a minimal fetch to fully initialize the framework
            // Use a specific name predicate (not empty) to avoid invalid predicate error
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor]
            let predicate = CNContact.predicateForContacts(matchingName: "zzz_prewarm_unlikely_name")
            do {
                // This will return empty results but initializes the framework
                _ = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            } catch {
                // Expected to fail or return empty - framework is still warmed
            }
        }
    }
}

// Keep old name for compatibility
typealias WebKitPrewarmer = AppPrewarmer
