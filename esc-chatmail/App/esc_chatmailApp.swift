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
    @StateObject private var authSession = AuthSession.shared
    @Environment(\.scenePhase) var scenePhase
    
    init() {
        configureGoogleSignIn()
        configureBackgroundTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authSession)
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
