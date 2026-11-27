import XCTest
@testable import esc_chatmail

/// `PendingActionsManagerProtocol`'s `within:` members are required witnesses with no
/// protocol-extension default. The defaults that were there until 2026-11-27 forwarded a
/// missing or mistyped witness to the acquiring overloads, which call `acquireRun`:
/// `MessageActions` calls `within:` while it holds a conversation's turn and sync waits on
/// that turn, so the fallback was a permanent hang that compiled (architecture review
/// 2026-11, invariant-enforcement#2). Now a conformer that forgets one fails to compile,
/// which no runtime test can show; this pins the absence of the defaults from source.
final class PendingActionsManagerProtocolSourceTests: XCTestCase {
    // Revert-check: fails if an `extension PendingActionsManagerProtocol` is added back to
    // the protocol's file, or if either `within:` requirement leaves the protocol.
    func testProtocol_hasNoExtensionDefaults_andRequiresBothWithinWitnesses() throws {
        let source = try repositorySource("esc-chatmail/Services/PendingActions/PendingActionsManagerProtocol.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(
            source.contains("extension PendingActionsManagerProtocol"),
            "A protocol-extension default turns a missing `within:` witness into the acquiring overload"
        )
        XCTAssertEqual(
            source.components(separatedBy: "within syncRun: SyncRun").count - 1,
            2,
            "Both `within:` members are requirements of the protocol"
        )
    }
}
