import Foundation

/// Set by an inline recovery that found no room for the requested part
/// (`SynthesizedInlineAttachmentRecovery.recover(…requestedFoundNoRoom:)`) and read by the
/// downloader once the recovery has returned. `@unchecked Sendable`: guarded by `lock`.
final class RecoveryRoomFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
