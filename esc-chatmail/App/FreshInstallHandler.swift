import Foundation
import GoogleSignIn

/// Handles fresh install detection and cleanup.
///
/// On iOS, the keychain persists across app deletions while UserDefaults does not.
/// This creates a scenario where a reinstalled app has stale keychain credentials
/// but no UserDefaults data. This handler detects and cleans up this state.
struct FreshInstallHandler {
    private let userDefaults: UserDefaults
    private let keychainService: KeychainService

    private static let installationKey = "AppInstallationID"
    private static let installTimestampKey = "installTimestamp"
    private static let isFreshInstallKey = "isFreshInstall"

    init(
        userDefaults: UserDefaults = .standard,
        keychainService: KeychainService = .shared
    ) {
        self.userDefaults = userDefaults
        self.keychainService = keychainService
    }

    /// Checks for fresh install and performs cleanup if needed.
    /// Should be called early in app launch, before auth restoration.
    func checkAndHandleFreshInstall() {
        let hasUserDefaultsID = userDefaults.string(forKey: Self.installationKey) != nil
        let hasKeychainData = (try? keychainService.loadString(for: .installationId)) != nil

        if !hasUserDefaultsID {
            handleFreshInstall(hasKeychainData: hasKeychainData)
        } else if let storedID = userDefaults.string(forKey: Self.installationKey) {
            verifyInstallationConsistency(storedID: storedID)
        }

        ensureInstallTimestampExists()
    }

    // MARK: - Private Methods

    private func handleFreshInstall(hasKeychainData: Bool) {
        Log.info("Fresh install detected - UserDefaults cleared", category: .auth)

        if hasKeychainData {
            Log.warning("Keychain data from previous installation found - cleaning up", category: .auth)
        }

        performCleanup()
        setupNewInstallation()
    }

    private func verifyInstallationConsistency(storedID: String) {
        if !keychainService.verifyInstallationId(storedID) {
            Log.warning("Installation ID mismatch - performing cleanup", category: .auth)
            performCleanup()
            setupNewInstallation()
        }
    }

    private func setupNewInstallation() {
        let newID = keychainService.getOrCreateInstallationId()
        let installTimestamp = Date().timeIntervalSince1970

        userDefaults.set(installTimestamp, forKey: Self.installTimestampKey)
        userDefaults.set(newID, forKey: Self.installationKey)
        userDefaults.set(true, forKey: Self.isFreshInstallKey)
        userDefaults.synchronize()

        Log.debug("Install timestamp recorded: \(installTimestamp) (\(Date()))", category: .auth)

        // Verify write succeeded
        if userDefaults.string(forKey: Self.installationKey) == nil {
            Log.warning("UserDefaults write failed, retrying...", category: .auth)
            userDefaults.set(installTimestamp, forKey: Self.installTimestampKey)
            userDefaults.set(newID, forKey: Self.installationKey)
            userDefaults.set(true, forKey: Self.isFreshInstallKey)
            userDefaults.synchronize()
        }

        Log.info("Fresh install setup complete with new ID: \(newID.prefix(8))...", category: .auth)
    }

    private func ensureInstallTimestampExists() {
        if userDefaults.double(forKey: Self.installTimestampKey) == 0 {
            let installTimestamp = Date().timeIntervalSince1970
            userDefaults.set(installTimestamp, forKey: Self.installTimestampKey)
            userDefaults.synchronize()
            Log.debug("Install timestamp was missing, set to: \(installTimestamp)", category: .auth)
        }
    }

    private func performCleanup() {
        Log.info("Performing fresh install cleanup...", category: .auth)

        signOutFromGoogle()
        clearAuthSession()
        clearKeychain()
        clearTokens()
        clearUserDefaults()
        clearCoreData()
        clearCaches()
        clearAttachmentFiles()

        Log.info("Fresh install cleanup complete", category: .auth)
    }

    private func signOutFromGoogle() {
        Log.debug("Signing out from Google", category: .auth)
        GIDSignIn.sharedInstance.signOut()
    }

    private func clearAuthSession() {
        Log.debug("Clearing AuthSession", category: .auth)
        Task { @MainActor in
            AuthSession.shared.currentUser = nil
            AuthSession.shared.isAuthenticated = false
            AuthSession.shared.userEmail = nil
            AuthSession.shared.userName = nil
            AuthSession.shared.accessToken = nil
        }
    }

    private func clearKeychain() {
        Log.debug("Clearing keychain", category: .auth)
        do {
            try KeychainService.shared.clearAll()
            Log.debug("Keychain cleared", category: .auth)
        } catch {
            Log.warning("Failed to clear keychain: \(error)", category: .auth)
        }
    }

    private func clearTokens() {
        Log.debug("Clearing tokens", category: .auth)
        Task { @MainActor in
            do {
                try TokenManager.shared.clearTokens()
                Log.debug("Tokens cleared", category: .auth)
            } catch {
                Log.warning("Failed to clear tokens: \(error)", category: .auth)
            }
        }
    }

    private func clearUserDefaults() {
        Log.debug("Clearing UserDefaults", category: .auth)
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            UserDefaults.standard.synchronize()
            Log.debug("UserDefaults cleared", category: .auth)
        }
    }

    private func clearCoreData() {
        Log.debug("Clearing Core Data", category: .coreData)
        do {
            try CoreDataStack.shared.destroyAndReloadSync()
            Log.debug("Core Data cleared and reloaded", category: .coreData)
        } catch {
            Log.warning("Failed to clear Core Data: \(error)", category: .coreData)
        }
    }

    private func clearCaches() {
        Log.debug("Clearing in-memory caches", category: .general)
        Task { @MainActor in
            ConversationCache.shared.clear()
        }
        Task {
            await PersonCache.shared.clearCache()
        }
        Log.debug("In-memory caches cleared", category: .general)

        Log.debug("Clearing attachment caches", category: .attachment)
        Task {
            await AttachmentCacheActor.shared.clearCache(level: .aggressive)
        }
    }

    private func clearAttachmentFiles() {
        Log.debug("Clearing attachment files", category: .attachment)
        let fileManager = FileManager.default

        // Clear Documents/Attachments and Documents/Messages
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: documentsURL.appendingPathComponent("Attachments"))
            try? fileManager.removeItem(at: documentsURL.appendingPathComponent("Messages"))
        }

        // Clear Application Support
        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: appSupportURL.appendingPathComponent("Attachments"))
            try? fileManager.removeItem(at: appSupportURL.appendingPathComponent("Previews"))
        }

        // Clear Caches
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: cacheURL.appendingPathComponent("AttachmentCache"))
        }

        Log.debug("Attachment files cleared", category: .attachment)
    }
}
