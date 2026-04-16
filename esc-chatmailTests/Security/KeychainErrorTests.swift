import XCTest
import Security
@testable import esc_chatmail

final class KeychainErrorTests: XCTestCase {

    func testErrorDescription_unhandledError_includesStatusCode() {
        let error = KeychainError.unhandledError(status: errSecDuplicateItem)
        XCTAssertTrue(error.errorDescription?.contains("\(errSecDuplicateItem)") ?? false)
    }

    func testErrorDescription_unexpectedData() {
        XCTAssertEqual(KeychainError.unexpectedData.errorDescription, "Unexpected data format in keychain")
    }

    func testErrorDescription_itemNotFound() {
        XCTAssertEqual(KeychainError.itemNotFound.errorDescription, "Item not found in keychain")
    }

    func testErrorDescription_duplicateItem() {
        XCTAssertEqual(KeychainError.duplicateItem.errorDescription, "Item already exists in keychain")
    }

    func testErrorDescription_invalidParameters() {
        XCTAssertEqual(KeychainError.invalidParameters.errorDescription, "Invalid keychain parameters")
    }

    // MARK: - AccessLevel

    func testAccessLevel_whenUnlocked_mapsToCorrectAttribute() {
        XCTAssertEqual(KeychainService.AccessLevel.whenUnlocked.attribute, kSecAttrAccessibleWhenUnlocked as String)
    }

    func testAccessLevel_whenUnlockedThisDeviceOnly_mapsToCorrectAttribute() {
        XCTAssertEqual(
            KeychainService.AccessLevel.whenUnlockedThisDeviceOnly.attribute,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    func testAccessLevel_afterFirstUnlock_mapsToCorrectAttribute() {
        XCTAssertEqual(KeychainService.AccessLevel.afterFirstUnlock.attribute, kSecAttrAccessibleAfterFirstUnlock as String)
    }

    func testAccessLevel_afterFirstUnlockThisDeviceOnly_mapsToCorrectAttribute() {
        XCTAssertEqual(
            KeychainService.AccessLevel.afterFirstUnlockThisDeviceOnly.attribute,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testAccessLevel_whenPasscodeSetThisDeviceOnly_mapsToCorrectAttribute() {
        XCTAssertEqual(
            KeychainService.AccessLevel.whenPasscodeSetThisDeviceOnly.attribute,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String
        )
    }

    // MARK: - Key rawValues

    func testKeys_allUseExpectedNamespace() {
        for key in KeychainService.Key.allCases {
            XCTAssertTrue(
                key.rawValue.hasPrefix("com.esc.inboxchat."),
                "Key \(key) should be namespaced, got \(key.rawValue)"
            )
        }
    }

    func testKeys_allRawValuesAreUnique() {
        let rawValues = KeychainService.Key.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count, "Keychain key rawValues should all be unique")
    }
}
