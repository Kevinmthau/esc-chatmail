import XCTest
@testable import esc_chatmail

/// The root screen `ContentView` publishes, as the launch smoke reads it
/// (`LaunchRootScreen`, `LaunchRootScreenRecord`, `Scripts/launch-smoke.sh`; architecture
/// review 2026-11, testing-ci-release#2, part 2). `ContentView` runs under no test plan, so
/// the decision is pinned here and its use there from source.
final class LaunchRootScreenTests: XCTestCase {
    // Revert-check: fails if the policy stops following ContentView's order (the mailbox
    // first, whatever the held account; then the held account; then sign-in).
    func testScreen_followsContentViewsBranches() {
        XCTAssertEqual(LaunchRootScreen.screen(canAccessMailbox: true, hasHeldAccount: false), .mailbox)
        XCTAssertEqual(LaunchRootScreen.screen(canAccessMailbox: true, hasHeldAccount: true), .mailbox)
        XCTAssertEqual(LaunchRootScreen.screen(canAccessMailbox: false, hasHeldAccount: true), .heldAccount)
        XCTAssertEqual(LaunchRootScreen.screen(canAccessMailbox: false, hasHeldAccount: false), .signIn)
    }

    /// The identifiers are what the smoke greps for, so they are pinned as values.
    // Revert-check: fails if an identifier changes or two coincide.
    func testIdentifiers_areDistinct_andTheSignInOneIsWhatTheSmokeExpects() {
        XCTAssertEqual(LaunchRootScreen.signIn.accessibilityIdentifier, "launch.root.signIn")
        XCTAssertEqual(LaunchRootScreen.heldAccount.accessibilityIdentifier, "launch.root.heldAccount")
        XCTAssertEqual(LaunchRootScreen.mailbox.accessibilityIdentifier, "launch.root.mailbox")
        XCTAssertEqual(Set(LaunchRootScreen.allCases.map(\.accessibilityIdentifier)).count, LaunchRootScreen.allCases.count)
        XCTAssertEqual(LaunchRootScreenRecord.category, "launch")
        XCTAssertEqual(LaunchRootScreenRecord.messagePrefix, "Root screen published: ")
    }

    /// `ContentView` carries the identifier on its root and records the root as it appears,
    /// and its branches are in the policy's order.
    // Revert-check: fails if ContentView drops the identifier, the record, or reorders its
    // branches against the policy.
    //
    // HONEST SCOPE: source text. That the record reaches the unified log of a Release build
    // is checked by the smoke itself, on CI's Release build.
    func testContentView_carriesTheIdentifier_recordsTheRoot_andBranchesInThePolicysOrder() throws {
        let source = try repositorySource("esc-chatmail/App/ContentView.swift")

        XCTAssertTrue(source.contains("let rootScreen = LaunchRootScreen.screen("))
        XCTAssertTrue(source.contains("canAccessMailbox: authSession.canAccessMailbox,"))
        XCTAssertTrue(source.contains("hasHeldAccount: authSession.heldAccount != nil"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(rootScreen.accessibilityIdentifier)"))
        XCTAssertTrue(source.contains("LaunchRootScreenRecord.record(rootScreen)"))

        let mailbox = try XCTUnwrap(source.range(of: "if authSession.canAccessMailbox {"))
        let held = try XCTUnwrap(source.range(of: "} else if let heldAccount = authSession.heldAccount {"))
        let signIn = try XCTUnwrap(source.range(of: "SignInView()"))
        XCTAssertLessThan(mailbox.lowerBound, held.lowerBound)
        XCTAssertLessThan(held.lowerBound, signIn.lowerBound)
    }
}
