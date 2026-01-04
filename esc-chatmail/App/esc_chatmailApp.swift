//
//  esc_chatmailApp.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI
import GoogleSignIn
import BackgroundTasks
import Security

@main
struct esc_chatmailApp: App {
    @StateObject private var dependencies = Dependencies.shared
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // IMPORTANT: Check for fresh install FIRST, before any auth restoration
        checkAndClearKeychainOnFreshInstall()

        configureGoogleSignIn()
        configureBackgroundTasks()

        // Initialize Core Data stack early
        _ = CoreDataStack.shared.persistentContainer

        // Setup attachment directories
        AttachmentPaths.setupDirectories()

        // NOW restore previous sign-in (after fresh install check)
        // This ensures we don't restore a session from a deleted app
        AuthSession.shared.restorePreviousSignIn()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, dependencies.viewContext)
                .environmentObject(dependencies)
                .environmentObject(dependencies.authSession) // backward compatibility
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }
    
    private func checkAndClearKeychainOnFreshInstall() {
        let installationKey = "AppInstallationID"
        let userDefaults = UserDefaults.standard
        let keychainService = KeychainService.shared

        // Check if we have a stored installation ID in UserDefaults
        let hasUserDefaultsID = userDefaults.string(forKey: installationKey) != nil

        // Check if we have keychain data (indicating previous installation)
        let hasKeychainData = (try? keychainService.loadString(for: .installationId)) != nil

        // Detect fresh install: No UserDefaults but has Keychain data
        // This happens when app is deleted and reinstalled
        if !hasUserDefaultsID {
            Log.info("Fresh install detected - UserDefaults cleared", category: .auth)

            if hasKeychainData {
                Log.warning("Keychain data from previous installation found - cleaning up", category: .auth)
            }

            // Perform cleanup regardless of keychain state
            performFreshInstallCleanup()

            // Generate and store new installation ID
            let newID = keychainService.getOrCreateInstallationId()

            // Record install timestamp for sync cutoff
            let installTimestamp = Date().timeIntervalSince1970
            userDefaults.set(installTimestamp, forKey: "installTimestamp")

            // Ensure we can write to UserDefaults after domain removal
            userDefaults.set(newID, forKey: installationKey)
            userDefaults.set(true, forKey: "isFreshInstall")
            userDefaults.synchronize()

            Log.debug("Install timestamp recorded: \(installTimestamp) (\(Date()))", category: .auth)

            // Verify the write succeeded - retry without blocking
            if userDefaults.string(forKey: installationKey) == nil {
                Log.warning("UserDefaults write failed, retrying...", category: .auth)
                userDefaults.set(installTimestamp, forKey: "installTimestamp")
                userDefaults.set(newID, forKey: installationKey)
                userDefaults.set(true, forKey: "isFreshInstall")
                userDefaults.synchronize()
            }

            Log.info("Fresh install setup complete with new ID: \(newID.prefix(8))...", category: .auth)
        } else if let storedID = userDefaults.string(forKey: installationKey) {
            // Verify the stored ID matches keychain
            if !keychainService.verifyInstallationId(storedID) {
                Log.warning("Installation ID mismatch - performing cleanup", category: .auth)
                performFreshInstallCleanup()
                let newID = keychainService.getOrCreateInstallationId()

                // Record install timestamp for sync cutoff (cleanup cleared it)
                let installTimestamp = Date().timeIntervalSince1970
                userDefaults.set(installTimestamp, forKey: "installTimestamp")
                userDefaults.set(newID, forKey: installationKey)
                userDefaults.set(true, forKey: "isFreshInstall")
                userDefaults.synchronize()

                Log.debug("Install timestamp recorded: \(installTimestamp) (\(Date()))", category: .auth)
            }
        }

        // Defensive check: ensure install timestamp exists
        // This catches any edge cases where it wasn't set properly
        if userDefaults.double(forKey: "installTimestamp") == 0 {
            let installTimestamp = Date().timeIntervalSince1970
            userDefaults.set(installTimestamp, forKey: "installTimestamp")
            userDefaults.synchronize()
            Log.debug("Install timestamp was missing, set to: \(installTimestamp)", category: .auth)
        }
    }
    
    private func performFreshInstallCleanup() {
        Log.info("Performing fresh install cleanup...", category: .auth)

        // 1. Sign out from Google (synchronous, safe to call during init)
        Log.debug("Signing out from Google", category: .auth)
        GIDSignIn.sharedInstance.signOut()

        // Note: We skip disconnect() during app init as it's async and blocks the UI
        // The signOut() above is sufficient to clear the local session
        // Disconnect will happen automatically on next sign-in if needed

        // 2. Clear AuthSession state
        Log.debug("Clearing AuthSession", category: .auth)
        Task { @MainActor in
            AuthSession.shared.currentUser = nil
            AuthSession.shared.isAuthenticated = false
            AuthSession.shared.userEmail = nil
            AuthSession.shared.userName = nil
            AuthSession.shared.accessToken = nil
        }

        // 3. Clear all keychain items
        Log.debug("Clearing keychain", category: .auth)
        do {
            try KeychainService.shared.clearAll()
            Log.debug("Keychain cleared", category: .auth)
        } catch {
            Log.warning("Failed to clear keychain: \(error)", category: .auth)
        }

        // 4. Clear tokens using TokenManager
        Log.debug("Clearing tokens", category: .auth)
        do {
            try TokenManager.shared.clearTokens()
            Log.debug("Tokens cleared", category: .auth)
        } catch {
            Log.warning("Failed to clear tokens: \(error)", category: .auth)
        }

        // 5. Clear UserDefaults completely
        Log.debug("Clearing UserDefaults", category: .auth)
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            // Force synchronization to ensure persistent domain removal completes
            UserDefaults.standard.synchronize()
            Log.debug("UserDefaults cleared", category: .auth)
        }

        // 6. Clear Core Data (synchronous to ensure it completes and reloads before sync starts)
        Log.debug("Clearing Core Data", category: .coreData)
        do {
            try CoreDataStack.shared.destroyAndReloadSync()
            Log.debug("Core Data cleared and reloaded", category: .coreData)
        } catch {
            Log.warning("Failed to clear Core Data: \(error)", category: .coreData)
        }

        // 7. Clear in-memory caches (already on main thread from init)
        Log.debug("Clearing in-memory caches", category: .general)
        ConversationCache.shared.clear()
        PersonCache.shared.clearCache()
        Log.debug("In-memory caches cleared", category: .general)

        // 8. Clear attachment caches
        Log.debug("Clearing attachment caches", category: .attachment)
        Task {
            await AttachmentCacheActor.shared.clearCache(level: .aggressive)
        }
        clearAttachmentFiles()
        Log.debug("Attachment caches cleared", category: .attachment)

        Log.info("Fresh install cleanup complete", category: .auth)
    }

    private func clearAttachmentFiles() {
        let fileManager = FileManager.default

        // Clear Documents/Attachments
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let attachmentsURL = documentsURL.appendingPathComponent("Attachments")
            try? fileManager.removeItem(at: attachmentsURL)

            let messagesURL = documentsURL.appendingPathComponent("Messages")
            try? fileManager.removeItem(at: messagesURL)
        }

        // Clear Application Support
        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let attachmentsURL = appSupportURL.appendingPathComponent("Attachments")
            try? fileManager.removeItem(at: attachmentsURL)

            let previewsURL = appSupportURL.appendingPathComponent("Previews")
            try? fileManager.removeItem(at: previewsURL)
        }

        // Clear Caches
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let attachmentCacheURL = cacheURL.appendingPathComponent("AttachmentCache")
            try? fileManager.removeItem(at: attachmentCacheURL)
        }
    }
    
    private func configureGoogleSignIn() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: GoogleConfig.clientId
        )
    }
    
    private func configureBackgroundTasks() {
        BackgroundSyncManager.shared.registerBackgroundTasks()
    }
    
    private func runDuplicateCleanup() async {
        let context = CoreDataStack.shared.newBackgroundContext()
        let conversationManager = ConversationManager()
        await conversationManager.mergeActiveConversationDuplicates(in: context)
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if dependencies.authSession.isAuthenticated {
                dependencies.backgroundSyncManager.scheduleAppRefresh()
                dependencies.backgroundSyncManager.scheduleProcessingTask()
            }
        case .active:
            // Note: Sync is handled by ConversationListView.onAppear to avoid duplicate syncs
            // Only process pending actions here (lightweight operation)
            if dependencies.authSession.isAuthenticated {
                Task {
                    await dependencies.pendingActionsManager.processAllPendingActions()
                    // Run lightweight duplicate cleanup on app activation
                    await runDuplicateCleanup()
                }
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        // This is called when the app is about to terminate
        // Only clear memory cache, but preserve user session
        // Full cleanup only happens on fresh install detection
        Task {
            await AttachmentCacheActor.shared.clearCache(level: .moderate)
        }
    }
}
