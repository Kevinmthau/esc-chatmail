import Foundation

/// Gmail's time as this process last heard it, carried forward on a monotonic clock.
///
/// `GmailAPIClient.performRetryingRequest` records the HTTP `Date` header of every 2xx
/// response to a request that may be retransmitted (never messages.send: nothing on the
/// send path may read, throw on or reclassify anything for this). The estimate is that
/// date plus the time since, measured on `ContinuousClock`, which a change of the wall
/// clock does not move and which keeps counting while the device sleeps.
///
/// In memory only, deliberately: it is never written to `UserDefaults` (in a Mac test host
/// the standard defaults are the preferences of the Mac app the user runs), and a launch
/// starts with no estimate, which answers with the device's time, as before this existed.
///
/// The header has one-second resolution and is stamped before the response travels, so the
/// estimate runs a little behind Gmail's true time. That direction is the safe one: an
/// `after:` floor drawn from it is earlier, never later.
///
/// A date more than `maximumPlausibleSkew` from the device's is not recorded: "earlier"
/// alone puts no limit on how much earlier, and one response with a broken `Date` (a
/// proxy with a wrong clock) would otherwise move every floor, and the stamp written from
/// it, arbitrarily far back. HONEST SCOPE: a device clock set more than that far ahead
/// gets no correction, as before this existed.
///
/// `@unchecked Sendable`: `anchor` is read and written only under `lock`; the other
/// stored properties are immutable `@Sendable` closures.
final class ServerClockEstimate: ServerTimeSource, @unchecked Sendable {
    static let shared = ServerClockEstimate()

    /// The largest difference between Gmail's time and the device's that is believed.
    static let maximumPlausibleSkew: TimeInterval = 30 * 86_400

    private struct Anchor {
        let serverDate: Date
        let elapsedAtRecord: Duration
    }

    private let lock = NSLock()
    private var anchor: Anchor?
    private let deviceNow: @Sendable () -> Date
    private let elapsed: @Sendable () -> Duration

    /// - Parameters:
    ///   - deviceNow: The device's wall clock.
    ///   - elapsed: A monotonic reading; only differences between two readings are used.
    init(
        deviceNow: @escaping @Sendable () -> Date = { Date() },
        elapsed: @escaping @Sendable () -> Duration = { ContinuousClock.now - ServerClockEstimate.continuousOrigin }
    ) {
        self.deviceNow = deviceNow
        self.elapsed = elapsed
    }

    private static let continuousOrigin = ContinuousClock.now

    /// Records an HTTP `Date` header. A missing or unparsable header records nothing, and
    /// nothing here throws.
    func recordResponseDate(httpDateHeader: String?) {
        guard let httpDateHeader, let serverDate = Self.parseHTTPDate(httpDateHeader) else {
            return
        }
        record(serverDate: serverDate)
    }

    func record(serverDate: Date) {
        guard abs(serverDate.timeIntervalSince(deviceNow())) <= Self.maximumPlausibleSkew else {
            return
        }
        let reading = elapsed()
        lock.lock()
        anchor = Anchor(serverDate: serverDate, elapsedAtRecord: reading)
        lock.unlock()
    }

    /// Gmail's time now, or nil when no response has been recorded in this process.
    var estimatedServerNow: Date? {
        lock.lock()
        let anchor = self.anchor
        lock.unlock()
        guard let anchor else { return nil }
        let since = elapsed() - anchor.elapsedAtRecord
        return anchor.serverDate.addingTimeInterval(Self.seconds(since))
    }

    func conservativeNow() -> Date {
        let device = deviceNow()
        guard let server = estimatedServerNow else { return device }
        return min(device, server)
    }

    func deviceClockLead() -> TimeInterval {
        guard let server = estimatedServerNow else { return 0 }
        return max(0, deviceNow().timeIntervalSince(server))
    }

    /// RFC 9110's IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), which Google's servers send.
    /// The obsolete forms are not accepted: an unparsable header records nothing.
    static func parseHTTPDate(_ value: String) -> Date? {
        httpDateFormatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    /// `DateFormatter` parsing is thread-safe once it is configured, and this one is never
    /// changed after it is made.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
