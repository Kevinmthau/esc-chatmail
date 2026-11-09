import XCTest
import UIKit
import Contacts
@testable import esc_chatmail

/// The Mac port routed several iOS-only reads through `Platform/` shims. On iOS each must return
/// exactly what the code read before, so the port changes nothing there; these pin that.
@MainActor
final class IOSPlatformShimTests: XCTestCase {
    /// Revert-check: changing the iOS branch of `PlatformScreen.width` makes this fail.
    func testPlatformScreenWidth_onIOS_isMainScreenWidth() {
        XCTAssertEqual(PlatformScreen.width, UIScreen.main.bounds.width)
    }

    /// The compact bubble cap is a fraction of the screen width on iOS, as before the port.
    ///
    /// HONEST SCOPE: on a screen 427 pt or wider (the Max sizes) the 320 cap decides, so there
    /// this passes whatever the width term reads; `testPlatformScreenWidth_onIOS_isMainScreenWidth`
    /// pins the width itself.
    func testCompactMaxBubbleWidth_onIOS_isScreenFractionCappedAt320() {
        XCTAssertEqual(MessageBubbleStyle.compact.maxBubbleWidth, min(UIScreen.main.bounds.width * 0.75, 320))
        XCTAssertEqual(MessageBubbleStyle.standard.maxBubbleWidth, 280)
    }

    /// Revert-check: changing the iOS branch of `PlatformSettingsURL.contactsAccess` makes this fail.
    func testContactsAccessSettingsURL_onIOS_isAppSettingsPage() {
        XCTAssertEqual(PlatformSettingsURL.contactsAccess, URL(string: UIApplication.openSettingsURLString))
    }

    /// Revert-check: swapping either iOS name in `PlatformNotificationNames` makes this fail.
    func testNotificationNames_onIOS_areUIKitNames() {
        XCTAssertEqual(PlatformNotificationNames.windowDidBecomeKey, UIWindow.didBecomeKeyNotification)
        XCTAssertEqual(
            PlatformNotificationNames.applicationDidBecomeActive,
            UIApplication.didBecomeActiveNotification
        )
    }

    /// iOS keeps ContactsUI's picker, so "Add to Existing Contact" and compose's contacts button
    /// stay.
    ///
    /// Revert-check: returning false from the iOS branch of `ContactsSheet.supportsContactPicker`
    /// makes this fail.
    func testContactsSheet_onIOS_supportsContactPicker() {
        XCTAssertTrue(ContactsSheet.supportsContactPicker)
    }
}
