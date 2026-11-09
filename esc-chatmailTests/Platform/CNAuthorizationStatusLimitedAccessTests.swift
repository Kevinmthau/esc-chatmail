import XCTest
import Contacts
@testable import esc_chatmail

/// `isLimitedAccess` replaced six `if #available(iOS 18.0, *), status == .limited` checks so
/// they compile on the Mac, where `.limited` does not exist. On iOS it must answer exactly as
/// those checks did, or limited-access users lose contact names, photos and editing.
final class CNAuthorizationStatusLimitedAccessTests: XCTestCase {
    /// Revert-check: returning `false` from the iOS 18 branch of
    /// `CNAuthorizationStatus.isLimitedAccess` makes this fail.
    func testIsLimitedAccess_limitedOnIOS18OrLater_isTrue() throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("`.limited` exists from iOS 18")
        }

        XCTAssertTrue(CNAuthorizationStatus.limited.isLimitedAccess)
    }

    /// Revert-check: returning `true` from `CNAuthorizationStatus.isLimitedAccess` makes this fail.
    func testIsLimitedAccess_otherStatuses_isFalse() {
        let others: [CNAuthorizationStatus] = [.authorized, .denied, .restricted, .notDetermined]

        for status in others {
            XCTAssertFalse(status.isLimitedAccess, "status \(status.rawValue)")
        }
    }
}
