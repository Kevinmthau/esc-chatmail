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
    /// True from a confirmed Settings-app sign-out until `signOut()` returns.
    /// `AuthSession` publishes no "signing out" state, and the mailbox stays on
    /// screen until teardown reaches `isAuthenticated = false`; the cleanup
    /// that follows runs behind the same overlay.
    @State private var isSigningOutFromSettingsApp = false
    @State private var signOutPrompter = SettingsAppSignOutPrompter()
    private let settingsAppPreferences = SettingsAppPreferences()

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
            if isSigningOutFromSettingsApp {
                signingOutOverlay
            }
        }
        // Mounted only after the launch restore finished (and never in the
        // unit-test host), so the first evaluation sees the restored session.
        .onAppear {
            settingsAppPreferences.publishAppVersion(
                SettingsAppPreferences.versionDisplayString(infoDictionary: Bundle.main.infoDictionary)
            )
            publishSettingsAppAccount()
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
            publishSettingsAppAccount()
            evaluateSettingsAppSignOutRequest(isSceneActive: scenePhase == .active)
        }
        .onChange(of: authSession.userEmail) {
            publishSettingsAppAccount()
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

    private func publishSettingsAppAccount() {
        settingsAppPreferences.publishAccountEmail(
            SettingsAppPreferences.displayedAccountEmail(
                isAuthenticated: authSession.isAuthenticated,
                userEmail: authSession.userEmail
            )
        )
    }

    /// Acts on the Settings app's Sign Out switch (`SettingsAppSignOutPolicy`).
    private func evaluateSettingsAppSignOutRequest(isSceneActive: Bool) {
        let isSignOutRequested = settingsAppPreferences.isSignOutRequested
        let decision = SettingsAppSignOutPolicy.decision(
            isSignOutRequested: isSignOutRequested,
            // Only asked when there is a request to judge: while signed out,
            // `isDurablySignedOut()` reads the keychain, and this runs on every
            // foregrounding and focus change.
            isDurablySignedOut: isSignOutRequested && authSession.isDurablySignedOut(),
            isRequestBeingHandled: isSigningOutFromSettingsApp || signOutPrompter.isConfirmationActive,
            isSceneActive: isSceneActive
        )
        switch decision {
        case .none:
            break
        case .discardRequest:
            settingsAppPreferences.clearSignOutRequest()
        case .confirm:
            signOutPrompter.presentConfirmation(
                accountEmail: SettingsAppPreferences.displayedAccountEmail(
                    isAuthenticated: authSession.isAuthenticated,
                    userEmail: authSession.userEmail
                ),
                onSignOut: { signOutFromSettingsApp() },
                onCancel: { settingsAppPreferences.clearSignOutRequest() }
            )
        }
    }

    /// The sign-out the Settings-app confirmation approved: the same
    /// `AuthSession.signOut()` the in-app Settings screen called. It starts
    /// from UI, never from inside another auth transition (the auth gate is
    /// not reentrant).
    private func signOutFromSettingsApp() {
        settingsAppPreferences.clearSignOutRequest()
        // The alert can outlive the account it was raised for.
        guard !authSession.isDurablySignedOut(), !isSigningOutFromSettingsApp else { return }
        isSigningOutFromSettingsApp = true
        Task {
            let didSignOut = await authSession.signOut()
            isSigningOutFromSettingsApp = false
            if !didSignOut {
                // Cleanup never began (the reset marker could not be saved), so
                // the account is still signed in; say so rather than nothing.
                Log.error("Settings-app sign-out did not start; the account is still signed in", category: .auth)
                signOutPrompter.presentFailure()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(Dependencies.shared)
        .environmentObject(Dependencies.shared.authSession)
}
