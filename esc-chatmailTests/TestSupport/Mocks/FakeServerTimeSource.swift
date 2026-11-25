import Foundation
@testable import esc_chatmail

/// A `ServerTimeSource` whose answer the test sets: the earlier of the device's time and a
/// server time `offset` seconds from it (negative: the device clock is ahead of Gmail's).
final class FakeServerTimeSource: ServerTimeSource, @unchecked Sendable {
    /// `@unchecked Sendable`: `offset` is read and written only under `lock`.
    private let lock = NSLock()
    private var _offset: TimeInterval

    init(serverOffsetFromDevice offset: TimeInterval) {
        _offset = offset
    }

    var serverOffsetFromDevice: TimeInterval {
        get { lock.withLock { _offset } }
        set { lock.withLock { _offset = newValue } }
    }

    func conservativeNow() -> Date {
        let device = Date()
        return min(device, device.addingTimeInterval(serverOffsetFromDevice))
    }
}
