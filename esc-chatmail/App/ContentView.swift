//
//  ContentView.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var dependencies: Dependencies
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settingsAppSignOut = SettingsAppSignOutController()

    var body: some View {
        Group {
            if authSession.canAccessMailbox {
                NavigationStack {
                    ConversationListView(deps: dependencies)
                }
            } else {
                SignInView()
            }
        }
        .overlay {
            if settingsAppSignOut.isSigningOut {
                signingOutOverlay
            }
        }
        // Mounted only after the launch restore finished (and never in the
        // unit-test host), so the first evaluation sees the restored session.
        // The Settings app's Account and Version rows are kept current from
        // launch by `SettingsAppAccountPublisher`, not from here.
        .onAppear {
            evaluateSettingsAppSignOutRequest(isSceneActive: scenePhase == .active)
        }
        // On iPhone the Settings app changes the switch while this app is in
        // the background, so returning to the foreground is the moment to look.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            evaluateSettingsAppSignOutRequest(isSceneActive: true)
        }
        // On iPad, Settings can sit beside this app with both scenes staying
        // active, so no phase change follows the switch; look again when this
        // app's window regains focus.
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in
            evaluateSettingsAppSignOutRequest(isSceneActive: scenePhase == .active)
        }
        .onChange(of: authSession.isAuthenticated) {
            evaluateSettingsAppSignOutRequest(isSceneActive: scenePhase == .active)
        }
    }

    /// Stands in for the old in-app Settings screen's "Signing Out..." state
    /// and swallows taps on the mailbox while it tears down. It draws inside
    /// the root view, so a sheet left open (Compose, a chat's sheets) stays on
    /// top of it until teardown removes the mailbox and SwiftUI dismisses the
    /// sheet; a send tapped there is refused, because `signOut()` closes
    /// outbound admission before its first suspension.
    private var signingOutOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            ProgressView("Signing Out…")
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Settings App

    /// Acts on the Settings app's Sign Out switch (`SettingsAppSignOutController`).
    private func evaluateSettingsAppSignOutRequest(isSceneActive: Bool) {
        settingsAppSignOut.evaluate(account: authSession, isSceneActive: isSceneActive)
    }
}

#Preview {
    ContentView()
        .environmentObject(Dependencies.shared)
        .environmentObject(Dependencies.shared.authSession)
}
