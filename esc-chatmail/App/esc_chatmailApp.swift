//
//  esc_chatmailApp.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI
import GoogleSignIn
import BackgroundTasks

@main
struct esc_chatmailApp: App {
    @StateObject private var dependencies = Dependencies.shared
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // IMPORTANT: Check for fresh install FIRST, before any auth restoration
        FreshInstallHandler().checkAndHandleFreshInstall()

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
