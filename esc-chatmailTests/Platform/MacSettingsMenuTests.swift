#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// The app menu the Mac app really builds once it has a Settings scene, read from the menu
/// bar of the Mac test host, which is the app itself.
///
/// HONEST SCOPE: no item is chosen and no Settings window is opened: the test host never
/// initializes the app, so its Settings scene has only a placeholder to show. This pins that
/// the scene put Settings… (Command-Comma) in the app menu and that Sign Out… still follows
/// it.
@MainActor
final class MacSettingsMenuTests: XCTestCase {
    /// Revert-check: deleting the `Settings { settingsContent }` scene from
    /// `esc_chatmailApp.body` makes this fail.
    func testAppMenu_hasSettingsWithCommandComma() throws {
        XCTAssertNotNil(try appMenu().items.first(where: Self.isSettingsItem))
    }

    /// The order every Mac app menu has: About, Settings…, then the app's own commands, then
    /// Services. With `CommandGroup(after: .appSettings)` Sign Out… came up above Settings….
    ///
    /// Revert-check: changing `SignOutCommands`' group back to `CommandGroup(after:
    /// .appSettings)` makes this fail.
    func testAppMenu_signOutFollowsSettings_inAGroupOfItsOwn() throws {
        let items = try appMenu().items
        let titles = items.map { $0.isSeparatorItem ? "---" : $0.title }
        let settingsIndex = try XCTUnwrap(items.firstIndex(where: Self.isSettingsItem), titles.description)
        let signOutIndex = try XCTUnwrap(items.firstIndex(where: { $0.title == "Sign Out…" }), titles.description)

        XCTAssertGreaterThan(signOutIndex, settingsIndex, titles.description)
        // Asked through `indices`, like the item after: an assertion that fails goes on, and
        // an index out of range would end the test host and the Mac plan's run with it.
        XCTAssertTrue(
            items.indices.contains(signOutIndex - 1) && items[signOutIndex - 1].isSeparatorItem,
            titles.description
        )
        // Revert-check: deleting the `Divider()` from `SignOutCommands`' group makes this
        // fail: Sign Out… would sit directly on Services.
        XCTAssertTrue(
            items.indices.contains(signOutIndex + 1) && items[signOutIndex + 1].isSeparatorItem,
            titles.description
        )
    }

    private func appMenu() throws -> NSMenu {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "The test host has no menu bar")
        return try XCTUnwrap(mainMenu.items.first?.submenu, "The menu bar has no app menu")
    }

    private static func isSettingsItem(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent == ","
            && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
    }
}
#endif
