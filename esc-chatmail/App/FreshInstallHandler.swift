import Foundation
import GoogleSignIn
import Security

/// Handles fresh install detection and cleanup.
///
/// On iOS, the keychain persists across app deletions while UserDefaults does not.
/// This creates a scenario where a reinstalled app has stale keychain credentials
/// but no UserDefaults data. This handler detects and cleans up this state.
struct FreshInstallHandler {
    private let userDefaults: UserDefaults
    private let keychainService: KeychainService
    private let loadInstallationId: @Sendable () throws -> String
    private let handleDetectedFreshInstall: (@Sendable (Bool) async -> Void)?

    private static let installationKey = "AppInstallationID"
    private static let installTimestampKey = "installTimestamp"
    private static let isFreshInstallKey = "isFreshInstall"

    /// Consecutive indeterminate keychain reads, accumulated across bootstrap
    /// retries. Static because AppStartupBootstrap constructs a fresh handler
    /// per preparation attempt; attempts are serialized by the bootstrap, so
    /// unsynchronized access is single-flight in practice. After
    /// `indeterminateReadBackstop` failures the handler stops deferring and
    /// lets startup proceed without fresh-install determination — a keychain
    /// that fails every read (e.g. errSecMissingEntitlement) must not pin the
    /// app to the loading screen forever, and destructive cleanup still never
    /// runs on uncertainty.
    private static var consecutiveIndeterminateReads = 0
    private static let indeterminateReadBackstop = 5

#if DEBUG
    static func resetIndeterminateReadBackstopForTesting() {
        consecutiveIndeterminateReads = 0
    }
#endif

    init(
        userDefaults: UserDefaults = .standard,
        keychainService: KeychainService = .shared,
        loadInstallationId: (@Sendable () throws -> String)? = nil,
        handleDetectedFreshInstall: (@Sendable (Bool) async -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.keychainService = keychainService
        self.loadInstallationId = loadInstallationId ?? {
            try keychainService.loadString(for: .installationId)
        }
        self.handleDetectedFreshInstall = handleDetectedFreshInstall
    }

    /// Checks for fresh install and performs cleanup if needed.
    /// Should be called early in app launch, before auth restoration.
    @discardableResult
    func checkAndHandleFreshInstall() async -> Bool {
        let hasUserDefaultsID = userDefaults.string(forKey: Self.installationKey) != nil
        let keychainInstallationId: String?
        do {
            keychainInstallationId = try loadInstallationId()
        } catch KeychainError.itemNotFound {
            keychainInstallationId = nil
        } catch KeychainError.unexpectedData {
            // The item exists but cannot be decoded as an installation ID.
            // Unlike an OSStatus failure, this is positive evidence that the
            // stored identity is unusable, so the fail-safe cleanup below is
            // appropriate.
            Log.error("Installation ID data is corrupt; performing fail-safe fresh-install cleanup", category: .auth)
            keychainInstallationId = nil
        } catch {
            // A Keychain OSStatus (including protected-data, service
            // availability, and I/O failures) does not prove that the item is
            // absent. Background launches are especially likely to encounter
            // temporary failures, so retry instead of entering the destructive
            // mismatch cleanup path.
            Self.consecutiveIndeterminateReads += 1
            guard Self.consecutiveIndeterminateReads >= Self.indeterminateReadBackstop else {
                Log.warning("Installation ID could not be read; deferring fresh-install handling: \(error.localizedDescription)", category: .auth)
                return false
            }
            // The keychain has failed every read this launch: proceed without
            // fresh-install determination rather than holding startup hostage
            // to a signal that will never arrive. No cleanup and no new
            // installation bookkeeping — determination resumes on the next
            // launch whose keychain answers.
            Log.error(
                "Installation ID unreadable after \(Self.consecutiveIndeterminateReads) consecutive attempts; proceeding without fresh-install determination",
                category: .auth,
                error: error
            )
            return true
        }
        Self.consecutiveIndeterminateReads = 0

        if !hasUserDefaultsID {
            await handleFreshInstall(hasKeychainData: keychainInstallationId != nil)
        } else if let storedID = userDefaults.string(forKey: Self.installationKey) {
            await verifyInstallationConsistency(
                storedID: storedID,
                keychainInstallationId: keychainInstallationId
            )
        }

        ensureInstallTimestampExists()
        return true
    }

    // MARK: - Private Methods

    private func handleFreshInstall(hasKeychainData: Bool) async {
        Log.info("Fresh install detected - UserDefaults cleared", category: .auth)

        if hasKeychainData {
            Log.warning("Keychain data from previous installation found - cleaning up", category: .auth)
        }

        if let handleDetectedFreshInstall {
            await handleDetectedFreshInstall(hasKeychainData)
        } else {
            await performCleanup()
            setupNewInstallation()
        }
    }

    private func verifyInstallationConsistency(
        storedID: String,
        keychainInstallationId: String?
    ) async {
        if keychainInstallationId != storedID {
            Log.warning("Installation ID mismatch - performing cleanup", category: .auth)
            if let handleDetectedFreshInstall {
                await handleDetectedFreshInstall(keychainInstallationId != nil)
            } else {
                await performCleanup()
                setupNewInstallation()
            }
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

    private func performCleanup() async {
        Log.info("Performing fresh install cleanup...", category: .auth)

        await disconnectGoogleSession()
        await clearAuthSession()
        clearKeychain()
        await clearTokens()
        clearUserDefaults()
        await clearCoreData()
        await clearCaches()
        clearAttachmentFiles()

        Log.info("Fresh install cleanup complete", category: .auth)
    }

    private func disconnectGoogleSession() async {
        Log.debug("Disconnecting Google session", category: .auth)

        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.disconnect { error in
                if let error {
                    GIDSignIn.sharedInstance.signOut()
                    Log.warning("Failed to disconnect Google session during fresh install cleanup: \(error.localizedDescription)", category: .auth)
                    Log.debug("Fell back to local Google sign-out during fresh install cleanup", category: .auth)
                } else {
                    Log.debug("Google session disconnected", category: .auth)
                }
                continuation.resume()
            }
        }
    }

    private func clearAuthSession() async {
        Log.debug("Clearing AuthSession", category: .auth)
        // Open-codes a subset of AuthSession.clearAuthState() and CANNOT reset
        // requiresReauthentication (private(set)). Unreachable with the flag
        // set today — fresh-install cleanup runs at first launch, before any
        // session could have required reauthentication — but if this ever
        // gains a mid-life caller, route through AuthSession instead.
        await MainActor.run {
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

    private func clearTokens() async {
        Log.debug("Clearing tokens", category: .auth)
        await MainActor.run {
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

    private func clearCoreData() async {
        Log.debug("Clearing Core Data", category: .coreData)
        do {
            try await CoreDataStack.shared.destroyAndReloadAsync()
            Log.debug("Core Data cleared and reloaded", category: .coreData)
        } catch {
            Log.warning("Failed to clear Core Data: \(error)", category: .coreData)
        }
    }

    private func clearCaches() async {
        Log.debug("Clearing in-memory caches", category: .general)
        await MainActor.run {
            ConversationCache.shared.clear()
        }
        await PersonCache.shared.clearCache()
        Log.debug("In-memory caches cleared", category: .general)

        Log.debug("Clearing attachment caches", category: .attachment)
        await AttachmentCacheActor.shared.clearForAccountTransition()
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
            try? fileManager.removeItem(at: appSupportURL.appendingPathComponent(AttachmentPaths.attachmentsFolder))
            try? fileManager.removeItem(at: appSupportURL.appendingPathComponent(AttachmentPaths.previewsFolder))
        }

        // Clear Caches
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: cacheURL.appendingPathComponent(AttachmentPaths.legacyAttachmentCacheFolder))
        }

        Log.debug("Attachment files cleared", category: .attachment)

        // Recreate directories for sync to use
        AttachmentPaths.setupDirectories()
        HTMLContentHandler.shared.ensureDirectoryExists()
        Log.debug("Storage directories recreated", category: .attachment)
    }
}
