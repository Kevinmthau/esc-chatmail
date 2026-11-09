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

    // Revert-check: fails if KeychainService.serviceQuery() drops
    // kSecUseDataProtectionKeychain (every query), or if clearAll() goes back to
    // building its own query without it (the last delete). On macOS such a query
    // reaches the older file-based keychain, where AccessLevel's attributes don't
    // apply (docs/mac-app-plan.md, PR C). The flag is unobservable on iOS, so
    // this reads the queries the service hands the Security framework.
    func testEveryOperation_anyKey_queriesDataProtectionKeychain() throws {
        let recorder = RecordingKeychainItems()
        let service = KeychainService(service: serviceName, itemOperations: recorder.operations)
        let key = "googleAccessToken"

        // The recorder answers add with errSecDuplicateItem, so save also
        // exercises its update fallback.
        try service.save(Data("first".utf8), for: key)
        XCTAssertThrowsError(try service.load(for: key))
        XCTAssertFalse(service.exists(for: key))
        try service.update(Data("second".utf8), for: key)
        try service.delete(for: key)
        try service.clearAll()

        XCTAssertEqual(
            recorder.calls.map(\.name),
            ["add", "update", "copyMatching", "copyMatching", "update", "delete", "delete"]
        )
        for call in recorder.calls {
            XCTAssertEqual(
                call.query[kSecUseDataProtectionKeychain as String] as? Bool,
                true,
                "\(call.name) must target the data protection keychain"
            )
            XCTAssertEqual(call.query[kSecAttrService as String] as? String, serviceName)
        }
    }

    #if os(iOS)
    // Revert-check: none.
    // HONEST SCOPE: no production change makes this fail. It pins the platform
    // fact the data protection flag relies on: iOS has a single keychain, so
    // items that builds without the flag saved (every signed-in install before
    // PR C) still load, update and delete through the flagged queries. If an
    // SDK ever made the flag change matching on iOS, this fails before an
    // update signs everyone out. iOS-only because on macOS the unflagged item
    // lands in the file-based keychain, which the flagged queries never see.
    func testFlaggedQueries_itemSavedWithoutDataProtectionFlag_stillMatchOnIOS() throws {
        let key = "googleRefreshToken"
        var legacyItem = unflaggedQuery(for: key)
        legacyItem[kSecValueData as String] = Data("legacy".utf8)
        legacyItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(legacyItem as CFDictionary, nil), errSecSuccess)

        XCTAssertTrue(keychainService.exists(for: key))
        XCTAssertEqual(try keychainService.loadString(for: key), "legacy")

        try keychainService.update(Data("rotated".utf8), for: key)
        XCTAssertEqual(try keychainService.loadString(for: key), "rotated")

        try keychainService.delete(for: key)
        XCTAssertFalse(keychainService.exists(for: key))
        XCTAssertEqual(SecItemCopyMatching(unflaggedQuery(for: key) as CFDictionary, nil), errSecItemNotFound)
    }
    #endif

    private func unflaggedQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName as Any,
            kSecAttrAccount as String: key
        ]
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

/// Records every query `KeychainService` hands the Security framework, and
/// answers add with `errSecDuplicateItem`, copyMatching with
/// `errSecItemNotFound`, and update and delete with success.
///
/// `@unchecked Sendable`: `lock` guards `recorded`, which the operation
/// closures append to and `calls` reads.
private final class RecordingKeychainItems: @unchecked Sendable {
    struct Call {
        let name: String
        let query: [String: Any]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var operations: KeychainItemOperations {
        KeychainItemOperations(
            add: { attributes, _ in
                self.record("add", attributes)
                return errSecDuplicateItem
            },
            copyMatching: { query, _ in
                self.record("copyMatching", query)
                return errSecItemNotFound
            },
            update: { query, _ in
                self.record("update", query)
                return errSecSuccess
            },
            delete: { query in
                self.record("delete", query)
                return errSecSuccess
            }
        )
    }

    private func record(_ name: String, _ query: CFDictionary) {
        let dictionary = (query as NSDictionary) as? [String: Any] ?? [:]
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Call(name: name, query: dictionary))
    }
}
