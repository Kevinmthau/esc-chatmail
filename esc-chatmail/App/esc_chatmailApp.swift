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
    @StateObject private var authSession = AuthSession.shared
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
                .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
                .environmentObject(authSession)
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
            print("🔍 Fresh install detected - UserDefaults cleared")

            if hasKeychainData {
                print("⚠️  Keychain data from previous installation found - cleaning up")
            }

            // Perform cleanup regardless of keychain state
            performFreshInstallCleanup()

            // Generate and store new installation ID
            let newID = keychainService.getOrCreateInstallationId()

            // Ensure we can write to UserDefaults after domain removal
            userDefaults.set(newID, forKey: installationKey)
            userDefaults.set(true, forKey: "isFreshInstall")
            userDefaults.synchronize()

            // Verify the write succeeded - retry without blocking
            if userDefaults.string(forKey: installationKey) == nil {
                print("⚠️  UserDefaults write failed, retrying...")
                userDefaults.set(newID, forKey: installationKey)
                userDefaults.set(true, forKey: "isFreshInstall")
                userDefaults.synchronize()
            }

            print("✅ Fresh install setup complete with new ID: \(newID.prefix(8))...")
        } else if let storedID = userDefaults.string(forKey: installationKey) {
            // Verify the stored ID matches keychain
            if !keychainService.verifyInstallationId(storedID) {
                print("⚠️  Installation ID mismatch - performing cleanup")
                performFreshInstallCleanup()
                let newID = keychainService.getOrCreateInstallationId()
                userDefaults.set(newID, forKey: installationKey)
                userDefaults.synchronize()
            }
        }
    }
    
    private func performFreshInstallCleanup() {
        print("🧹 Performing fresh install cleanup...")

        // 1. Sign out from Google (synchronous, safe to call during init)
        print("  → Signing out from Google")
        GIDSignIn.sharedInstance.signOut()

        // Note: We skip disconnect() during app init as it's async and blocks the UI
        // The signOut() above is sufficient to clear the local session
        // Disconnect will happen automatically on next sign-in if needed

        // 2. Clear AuthSession state
        print("  → Clearing AuthSession")
        Task { @MainActor in
            AuthSession.shared.currentUser = nil
            AuthSession.shared.isAuthenticated = false
            AuthSession.shared.userEmail = nil
            AuthSession.shared.userName = nil
            AuthSession.shared.accessToken = nil
        }

        // 3. Clear all keychain items
        print("  → Clearing keychain")
        do {
            try KeychainService.shared.clearAll()
            print("  ✓ Keychain cleared")
        } catch {
            print("  ⚠️  Failed to clear keychain: \(error)")
        }

        // 4. Clear tokens using TokenManager
        print("  → Clearing tokens")
        do {
            try TokenManager.shared.clearTokens()
            print("  ✓ Tokens cleared")
        } catch {
            print("  ⚠️  Failed to clear tokens: \(error)")
        }

        // 5. Clear UserDefaults completely
        print("  → Clearing UserDefaults")
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            // Force synchronization to ensure persistent domain removal completes
            UserDefaults.standard.synchronize()
            print("  ✓ UserDefaults cleared")
        }

        // 6. Clear Core Data
        print("  → Clearing Core Data")
        Task {
            do {
                try await CoreDataStack.shared.resetStore()
                print("  ✓ Core Data cleared")
            } catch {
                print("  ⚠️  Failed to clear Core Data: \(error)")
            }
        }

        // 7. Clear attachment caches
        print("  → Clearing attachment caches")
        AttachmentCache.shared.clearCache(level: .aggressive)
        clearAttachmentFiles()
        print("  ✓ Attachment caches cleared")

        print("✅ Fresh install cleanup complete")
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
    
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if AuthSession.shared.isAuthenticated {
                BackgroundSyncManager.shared.scheduleAppRefresh()
                BackgroundSyncManager.shared.scheduleProcessingTask()
            }
        case .active:
            // Note: Sync is handled by ConversationListView.onAppear to avoid duplicate syncs
            // Only process pending actions here (lightweight operation)
            if AuthSession.shared.isAuthenticated {
                Task {
                    await PendingActionsManager.shared.processAllPendingActions()
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
        AttachmentCache.shared.clearCache(level: .moderate)
    }
}
