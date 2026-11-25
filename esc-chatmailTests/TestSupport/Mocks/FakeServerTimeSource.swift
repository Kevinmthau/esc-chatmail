import Foundation
@testable import esc_chatmail

/// A `ServerTimeSource` whose answer the test sets: the earlier of the device's time and a
/// server time `offset` seconds from it (negative: the device clock is ahead of Gmail's).
final class FakeServerTimeSource: ServerTimeSource, @unchecked Sendable {
    /// `@unchecked Sendable`: `offset` is read and written only under `lock`.
    private let lock = NSLock()
    private var _offset: TimeInterval
    private let reportsLead: Bool

    /// - Parameter reportsLead: false makes `deviceClockLead()` answer zero whatever the
    ///   offset, for a test that pins the use of `conservativeNow()` alone.
    init(serverOffsetFromDevice offset: TimeInterval, reportsLead: Bool = true) {
        _offset = offset
        self.reportsLead = reportsLead
    }

    var serverOffsetFromDevice: TimeInterval {
        get { lock.withLock { _offset } }
        set { lock.withLock { _offset = newValue } }
    }

    func deviceClockLead() -> TimeInterval {
        reportsLead ? max(0, -serverOffsetFromDevice) : 0
    }

    func conservativeNow() -> Date {
        let device = Date()
        return min(device, device.addingTimeInterval(serverOffsetFromDevice))
    }
}
