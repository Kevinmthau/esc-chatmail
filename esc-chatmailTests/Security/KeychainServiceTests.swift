import XCTest
import Security
@testable import esc_chatmail

final class KeychainServiceTests: XCTestCase {
    private var serviceName: String!
    private var keychainService: KeychainService!

    override func setUp() {
        super.setUp()
        serviceName = "KeychainServiceTests.\(UUID().uuidString)"
        keychainService = KeychainService(service: serviceName)
    }

    override func tearDown() {
        try? keychainService.clearAll()
        keychainService = nil
        serviceName = nil
        super.tearDown()
    }

    func testSave_updatesAccessibilityForDuplicateItem() throws {
        let key = "googleUserEmail"

        try keychainService.saveString(
            "first@example.com",
            for: key,
            withAccess: .whenUnlockedThisDeviceOnly
        )
        try keychainService.saveString(
            "second@example.com",
            for: key,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )

        XCTAssertEqual(try keychainService.loadString(for: key), "second@example.com")
        XCTAssertEqual(
            try accessibilityAttribute(for: key),
            KeychainService.AccessLevel.afterFirstUnlockThisDeviceOnly.attribute
        )
    }

    private func accessibilityAttribute(for key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName as Any,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }

        guard
            let attributes = result as? [String: Any],
            let accessible = attributes[kSecAttrAccessible as String] as? String
        else {
            throw KeychainError.unexpectedData
        }

        return accessible
    }
}
