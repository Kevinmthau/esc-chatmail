import WebKit
import Contacts

/// Pre-warms expensive subsystems to avoid freezes on first use.
///
/// Warms up:
/// - WebKit processes (WebContent, GPU, Networking) - ~3 seconds on first WKWebView
/// - OAuth token refresh - ~10 seconds on first API call after app launch
/// - Contacts framework - ~1 second on first CNContactStore access
///
/// `prewarmAll()` (ConversationListView.onAppear) warms the API and Contacts
/// only. WebKit is deliberately warmed solely by the post-init task in
/// `esc_chatmailApp.initializeApp()`, which calls `prewarmWebKitIfNeeded()`
/// about two seconds after init: launching the WebContent/GPU/Networking
/// processes during the first list layout passes contended with the first
/// sync and the launch repair passes, and warming it from `prewarmAll()`
/// left that deliberate deferral a no-op on every authenticated launch.
enum AppPrewarmer {
    private static var hasPrewarmedWebKit = false
    private static var hasPrewarmedAPI = false
    private static var hasPrewarmedContacts = false

    /// Pre-warms the API and Contacts subsystems. Safe to call multiple times.
    /// WebKit is not included on purpose; see the type doc.
    @MainActor
    static func prewarmAll() {
        prewarmAPIIfNeeded()
        prewarmContactsIfNeeded()
    }

    /// Pre-warms WebKit processes. Called only by the post-init task in
    /// `esc_chatmailApp.initializeApp()`, never from `prewarmAll()`.
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
