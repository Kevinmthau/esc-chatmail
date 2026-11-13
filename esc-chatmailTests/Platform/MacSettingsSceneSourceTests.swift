import XCTest
@testable import esc_chatmail

/// The wiring of the Mac's Settings window and of the quit that keeps it from holding the
/// app open, read from source.
///
/// HONEST SCOPE: this reads source text, so it runs in the iOS suite and in CI although the
/// code is Mac-only, and it matches the spelling of the source. It pins that the scene is
/// there and waits for the app to initialize, that the mailbox window's id is the one whose
/// closing quits, that the delegate starts the observer outside the test host, that the quit
/// is asked for from the run loop, and that the Settings view shows its own alerts and
/// publishes the menu command. Nobody has seen the window; what closing does was measured in
/// a stand-in program (`MacMainWindowPolicy`).
final class MacSettingsSceneSourceTests: XCTestCase {
    /// Revert-check: deleting the `Settings { settingsContent }` scene from
    /// `esc_chatmailApp.body` makes this fail.
    func testApp_hasTheSettingsScene() throws {
        let app = try source("esc-chatmail/App/esc_chatmailApp.swift")

        XCTAssertTrue(app.contains("        Settings {\n            settingsContent\n        }"), app)
    }

    /// Before the app has initialized the session is the unrestored placeholder, and a
    /// sign-out asked for then would run ahead of the fresh-install check and the restore.
    ///
    /// Revert-check: mounting `MacSettingsView` without the `if isInitialized` in
    /// `esc_chatmailApp.settingsContent` makes this fail.
    func testApp_settingsWaitForInitialization() throws {
        let app = try source("esc-chatmail/App/esc_chatmailApp.swift")
        let start = try XCTUnwrap(app.range(of: "private var settingsContent: some View {"))
        let content = String(app[start.upperBound...])

        let gate = try XCTUnwrap(content.range(of: "if isInitialized {"))
        let view = try XCTUnwrap(content.range(of: "MacSettingsView(authSession: dependencies.authSession)"))
        XCTAssertLessThan(gate.lowerBound, view.lowerBound)
        XCTAssertEqual(app.components(separatedBy: "MacSettingsView(").count - 1, 1)
    }

    /// The observer quits for the window with this id and no other.
    ///
    /// Revert-check: giving the `Window` scene any other id in `esc_chatmailApp.body` makes
    /// this fail: closing the mailbox window with Settings open would leave the app running.
    func testApp_mailboxWindowHasTheIDWhoseClosingQuits() throws {
        let app = try source("esc-chatmail/App/esc_chatmailApp.swift")

        XCTAssertTrue(app.contains(#"Window("MushMail", id: MacMainWindowPolicy.windowID) {"#))
    }

    /// Revert-check: deleting `observer.start()` from
    /// `MacAppDelegate.applicationDidFinishLaunching` makes this fail, and so does deleting
    /// the guard above it: a test that closed a window named `main` would end the test host.
    func testDelegate_startsTheCloseObserver_outsideTheTestHost() throws {
        let delegate = try source("esc-chatmail/Platform/MacAppDelegate.swift")
        let start = try XCTUnwrap(delegate.range(of: "func applicationDidFinishLaunching(_ notification: Notification) {"))
        let end = try XCTUnwrap(delegate.range(of: "\n    }\n", range: start.upperBound..<delegate.endIndex))
        let body = String(delegate[start.upperBound..<end.lowerBound])

        let guardRange = try XCTUnwrap(body.range(of: "guard !RuntimeEnvironment.isRunningUnitTests else { return }"))
        let startRange = try XCTUnwrap(body.range(of: "observer.start()"))
        XCTAssertLessThan(guardRange.lowerBound, startRange.lowerBound)
        XCTAssertTrue(body.contains("mainWindowCloseObserver = observer"), body)
    }

    /// Asked from a block on the main queue, or from a main-actor task, the quit hangs while a
    /// send is in flight (`MacMainWindowCloseObserver`).
    ///
    /// Revert-check: replacing the body of `MacMainWindowCloseObserver.quitFromRunLoop` with
    /// `DispatchQueue.main.async { NSApp.terminate(nil) }` makes this fail.
    func testObserver_asksToQuitFromTheRunLoop() throws {
        let observer = try source("esc-chatmail/Platform/MacMainWindowCloseObserver.swift")
        let code = observer
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(
            code.contains("NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)"),
            code
        )
        XCTAssertFalse(code.contains("DispatchQueue"), code)
        XCTAssertFalse(code.contains("Task {"), code)
        XCTAssertFalse(code.contains("Task("), code)
    }

    /// Revert-check: deleting `.settingsAppSignOutAlerts(for: signOut)` from
    /// `MacSettingsView.body` makes this fail: Sign Out… in the window would ask nothing.
    func testSettingsView_showsItsOwnSignOutAlerts() throws {
        let view = try source("esc-chatmail/Platform/MacSettingsView.swift")

        XCTAssertTrue(view.contains(".settingsAppSignOutAlerts(for: signOut)"))
        XCTAssertTrue(view.contains("signOutAction.perform()"))
        XCTAssertTrue(view.contains(".disabled(!signOutAction.isEnabled)"))
    }

    /// Revert-check: deleting `.signOutMenuAction(controller: signOut, account: authSession)`
    /// from `MacSettingsView.body` makes this fail: the app menu's Sign Out… would be
    /// disabled whenever the Settings window is in front.
    func testSettingsView_publishesTheMenuCommand() throws {
        let view = try source("esc-chatmail/Platform/MacSettingsView.swift")

        XCTAssertTrue(view.contains(".signOutMenuAction(controller: signOut, account: authSession)"))
    }

    private func source(_ path: String) throws -> String {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
