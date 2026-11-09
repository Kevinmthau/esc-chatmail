import XCTest
@testable import esc_chatmail

/// `ExternalURLOpener.open(_:on:systemCanOpen:systemOpen:)` runs both platforms' scheme rules under
/// the iOS test plan, with recording closures in place of `UIApplication.canOpenURL` and of
/// `NSWorkspace.open` / `UIApplication.open`.
///
/// HONEST SCOPE: `open(_:)` itself, which passes `AppPlatform.current` and the real system query
/// and hand-off, is not exercised (it would open URLs in the test host), so these do not prove
/// that the real closures call `canOpenURL` and `open`.
@MainActor
final class ExternalURLOpenerTests: XCTestCase {
    private var queried: [URL] = []
    private var opened: [URL] = []

    private func open(_ string: String, on platform: AppPlatform, systemCanOpen: Bool) throws {
        let url = try XCTUnwrap(URL(string: string))
        ExternalURLOpener.open(
            url,
            on: platform,
            systemCanOpen: {
                queried.append($0)
                return systemCanOpen
            },
            systemOpen: { opened.append($0) }
        )
    }

    /// The Mac never asks the system: even a query that would answer yes does not widen its list.
    ///
    /// Revert-check: removing the `.macOS` guard from
    /// `ExternalURLOpener.open(_:on:systemCanOpen:systemOpen:)` makes this fail; the Mac then hands
    /// `smb:` to `NSWorkspace.open`, which mounts the share.
    func testOpen_onMac_otherAppScheme_neverReachesSystem() throws {
        try open("smb://attacker.example/share", on: .macOS, systemCanOpen: true)
        try open("ssh://admin@example.com", on: .macOS, systemCanOpen: true)
        try open("com.googleusercontent.apps.123-abc:/oauth2redirect?code=stolen", on: .macOS, systemCanOpen: true)

        XCTAssertEqual(opened, [])
        XCTAssertEqual(queried, [])
    }

    func testOpen_onMac_everyPlatformScheme_reachesSystem() throws {
        try open("https://example.com/path", on: .macOS, systemCanOpen: false)
        try open("mailto:someone@example.com", on: .macOS, systemCanOpen: false)

        XCTAssertEqual(opened, [URL(string: "https://example.com/path")!, URL(string: "mailto:someone@example.com")!])
    }

    /// `canOpenURL` refused `mailto:`, `tel:` and `facetime:` on the iOS 27.0 simulator, which has
    /// no Mail, Phone or FaceTime to claim them, so iOS must not ask it for the shared list.
    ///
    /// Revert-check: dropping `opensOnEveryPlatform ||` from the `.iOS` guard in
    /// `ExternalURLOpener.open(_:on:systemCanOpen:systemOpen:)`, so every link waits on the query
    /// again, makes this fail.
    func testOpen_oniOS_everyPlatformScheme_opensWithoutAskingSystem() throws {
        let links = [
            "mailto:someone@example.com",
            "tel:+15555550100",
            "facetime:someone@example.com",
            "facetime-audio:+15555550100",
            "sms:+15555550100",
            "https://example.com/path",
            "HTTP://example.com"
        ]

        for link in links {
            try open(link, on: .iOS, systemCanOpen: false)
        }

        XCTAssertEqual(opened, links.map { URL(string: $0)! })
        XCTAssertEqual(queried, [])
    }

    /// Revert-check: opening unconditionally on iOS (dropping the `.iOS` guard in
    /// `ExternalURLOpener.open(_:on:systemCanOpen:systemOpen:)`) makes this fail.
    func testOpen_oniOS_otherScheme_systemRefuses_neverReachesSystem() throws {
        try open("zoommtg://zoom.us/join?confno=123", on: .iOS, systemCanOpen: false)

        XCTAssertEqual(opened, [])
        XCTAssertEqual(queried, [URL(string: "zoommtg://zoom.us/join?confno=123")!])
    }

    /// iOS leaves a scheme outside the shared list to `canOpenURL`, which does accept `smb:` (the
    /// Files app claims it), where the Mac refuses it.
    ///
    /// Revert-check: applying the Mac's rule on every platform in
    /// `ExternalURLOpener.open(_:on:systemCanOpen:systemOpen:)` makes this fail.
    func testOpen_oniOS_otherScheme_systemAccepts_reachesSystem() throws {
        try open("smb://fileserver.example.com/share", on: .iOS, systemCanOpen: true)

        XCTAssertEqual(opened, [URL(string: "smb://fileserver.example.com/share")!])
    }
}
