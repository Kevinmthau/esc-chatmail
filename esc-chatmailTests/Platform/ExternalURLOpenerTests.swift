import XCTest
@testable import esc_chatmail

/// `ExternalURLOpener.open(_:on:systemOpen:)` runs the Mac's scheme rule under the iOS test plan,
/// with a recording closure in place of `NSWorkspace.open` / `UIApplication.open`.
///
/// HONEST SCOPE: `open(_:)` itself, which passes `AppPlatform.current` and the real system
/// hand-off, is not exercised (it would open URLs in the test host), so these do not prove the
/// iOS-only `canOpenURL` check inside that hand-off.
@MainActor
final class ExternalURLOpenerTests: XCTestCase {
    private var opened: [URL] = []

    override func setUp() {
        super.setUp()
        opened = []
    }

    private func open(_ string: String, on platform: AppPlatform) throws {
        let url = try XCTUnwrap(URL(string: string))
        ExternalURLOpener.open(url, on: platform) { opened.append($0) }
    }

    /// Revert-check: removing the `.macOS` guard from `ExternalURLOpener.open(_:on:systemOpen:)`
    /// makes this fail; the Mac then hands `smb:` to `NSWorkspace.open`, which mounts the share.
    func testOpen_onMac_otherAppScheme_neverReachesSystem() throws {
        try open("smb://attacker.example/share", on: .macOS)
        try open("ssh://admin@example.com", on: .macOS)
        try open("com.googleusercontent.apps.123-abc:/oauth2redirect?code=stolen", on: .macOS)

        XCTAssertEqual(opened, [])
    }

    func testOpen_onMac_allowedScheme_reachesSystem() throws {
        try open("https://example.com/path", on: .macOS)
        try open("mailto:someone@example.com", on: .macOS)

        XCTAssertEqual(opened, [URL(string: "https://example.com/path")!, URL(string: "mailto:someone@example.com")!])
    }

    /// iOS leaves the decision to `canOpenURL` inside its system hand-off, as before the Mac rule.
    ///
    /// Revert-check: applying `EmailLinkSchemePolicy.allowsOpeningOnMac(_:)` on every platform in
    /// `ExternalURLOpener.open(_:on:systemOpen:)` makes this fail.
    func testOpen_oniOS_anyScheme_reachesSystemGate() throws {
        try open("smb://fileserver.example.com/share", on: .iOS)

        XCTAssertEqual(opened, [URL(string: "smb://fileserver.example.com/share")!])
    }
}
