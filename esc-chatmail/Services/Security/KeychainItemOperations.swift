import Foundation
import Security

/// The four Security framework calls `KeychainService` makes.
///
/// Injectable so a test can read every query the service issues:
/// `kSecUseDataProtectionKeychain` has no observable effect on iOS, so the
/// queries themselves are the only place to pin it there. Production uses
/// `.system`.
struct KeychainItemOperations: Sendable {
    var add: @Sendable (_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var copyMatching: @Sendable (_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var update: @Sendable (_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus
    var delete: @Sendable (_ query: CFDictionary) -> OSStatus

    static let system = KeychainItemOperations(
        add: { attributes, result in SecItemAdd(attributes, result) },
        copyMatching: { query, result in SecItemCopyMatching(query, result) },
        update: { query, attributesToUpdate in SecItemUpdate(query, attributesToUpdate) },
        delete: { query in SecItemDelete(query) }
    )
}
