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
        // Check if this is a fresh install and clear keychain if needed
        checkAndClearKeychainOnFreshInstall()
        
        configureGoogleSignIn()
        configureBackgroundTasks()
        // Initialize Core Data stack early
        _ = CoreDataStack.shared.persistentContainer
        // Setup attachment directories
        AttachmentPaths.setupDirectories()
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
        
        // Check if we have a stored installation ID
        if let storedID = userDefaults.string(forKey: installationKey) {
            // Check if this ID exists in keychain - if not, it's a fresh install
            if !verifyInstallationInKeychain(storedID) {
                performFreshInstallCleanup()
                // Generate and store new installation ID
                let newID = UUID().uuidString
                userDefaults.set(newID, forKey: installationKey)
                saveInstallationToKeychain(newID)
            }
        } else {
            // No installation ID found - this is definitely a fresh install
            performFreshInstallCleanup()
            // Generate and store new installation ID
            let newID = UUID().uuidString
            userDefaults.set(newID, forKey: installationKey)
            saveInstallationToKeychain(newID)
        }
    }
    
    private func performFreshInstallCleanup() {
        // Clear all keychain items
        clearAllKeychainItems()
        
        // Sign out and disconnect from Google
        GIDSignIn.sharedInstance.signOut()
        GIDSignIn.sharedInstance.disconnect { _ in
            // Ignore errors - we're just ensuring cleanup
        }
        
        // Clear any cached authentication state
        AuthSession.shared.currentUser = nil
        AuthSession.shared.isAuthenticated = false
        AuthSession.shared.userEmail = nil
        AuthSession.shared.accessToken = nil
    }
    
    private func verifyInstallationInKeychain(_ installID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "AppInstallationID",
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.esc.inboxchat",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let storedID = String(data: data, encoding: .utf8) {
            return storedID == installID
        }
        
        return false
    }
    
    private func saveInstallationToKeychain(_ installID: String) {
        guard let data = installID.data(using: .utf8) else { return }
        
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "AppInstallationID",
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.esc.inboxchat"
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "AppInstallationID",
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.esc.inboxchat",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    private func clearAllKeychainItems() {
        // Clear all keychain items that might contain Google Sign-In data
        let secItemClasses = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]
        
        for itemClass in secItemClasses {
            let spec: NSDictionary = [kSecClass: itemClass]
            SecItemDelete(spec)
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
            if AuthSession.shared.isAuthenticated {
                Task {
                    try? await SyncEngine.shared.performInitialSync()
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
    
    // These methods are preserved but only called during fresh install cleanup
    // They are NOT called on normal app termination to preserve user session
    private func clearKeychain() {
        // Clear any keychain items associated with the app
        let secItemClasses = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]
        
        for itemClass in secItemClasses {
            let spec: NSDictionary = [kSecClass: itemClass]
            SecItemDelete(spec)
        }
    }
    
    private func clearAttachmentFiles() {
        // Clear attachment directories
        let fileManager = FileManager.default
        
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let attachmentsURL = documentsURL.appendingPathComponent("Attachments")
            try? fileManager.removeItem(at: attachmentsURL)
        }
        
        // Clear cache directory
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let attachmentCacheURL = cacheURL.appendingPathComponent("AttachmentCache")
            try? fileManager.removeItem(at: attachmentCacheURL)
        }
        
        // Clear temporary directory
        let tempURL = fileManager.temporaryDirectory
        if let contents = try? fileManager.contentsOfDirectory(at: tempURL, includingPropertiesForKeys: nil) {
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }
    }
    
    private func clearUserDefaults() {
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            UserDefaults.standard.synchronize()
        }
    }
}
