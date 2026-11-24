import XCTest
@testable import esc_chatmail

/// The `App` struct and `ContentView` run under no test, so where they start the retries
/// and show the held account is pinned from source.
final class LaunchRestoreRetrySourceTests: XCTestCase {
    // Revert-check: fails if `initializeApp()` stops starting the coordinator, or starts it
    // before `isInitialized = true` (a retry could then run ahead of the launch's restore).
    func testInitializeApp_startsRetriesOnlyOnceInitialized() throws {
        let source = try repositorySource("esc-chatmail/App/esc_chatmailApp.swift")
        let initialized = try XCTUnwrap(source.range(of: "isInitialized = true"))
        let start = try XCTUnwrap(source.range(of: "launchRestoreRetryCoordinator.start(isInBackground:"))
        XCTAssertLessThan(initialized.lowerBound, start.lowerBound)
    }

    // Revert-check: fails if the scene-phase or system-event handler stops handing its
    // event to the coordinator: the account would come back only on Try Again.
    func testLifecycleHandlers_handTheirEventsToTheCoordinator() throws {
        let source = try repositorySource("esc-chatmail/App/esc_chatmailApp.swift")
        XCTAssertTrue(source.contains("LaunchRestoreRetryPolicy.response(toScenePhase: newPhase, platform: .current)"))
        XCTAssertTrue(source.contains("LaunchRestoreRetryPolicy.response(toSystemEvent: event)"))
        XCTAssertTrue(source.contains("AppLifecyclePolicy.armsBackgroundTasksOnAuthChange("))
    }

    // Revert-check: fails if `ContentView` stops showing `HeldAccountView` for a held
    // account, or asks for it before `canAccessMailbox`.
    func testContentView_showsTheHeldAccountBetweenMailboxAndSignIn() throws {
        let source = try repositorySource("esc-chatmail/App/ContentView.swift")
        let mailbox = try XCTUnwrap(source.range(of: "if authSession.canAccessMailbox {"))
        let held = try XCTUnwrap(source.range(of: "} else if let heldAccount = authSession.heldAccount {"))
        let heldView = try XCTUnwrap(source.range(of: "HeldAccountView("))
        let signIn = try XCTUnwrap(source.range(of: "SignInView()"))
        XCTAssertLessThan(mailbox.lowerBound, held.lowerBound)
        XCTAssertLessThan(held.lowerBound, heldView.lowerBound)
        XCTAssertLessThan(heldView.lowerBound, signIn.lowerBound)
    }
}
