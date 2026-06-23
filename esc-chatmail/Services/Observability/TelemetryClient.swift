import Foundation

enum TelemetryEventName: String, Sendable {
    case appLaunch
    case syncCompleted
    case syncFailed
    case rateLimited
    case webViewRenderFailed
    case coreDataRecovery
    case backgroundTaskCompleted
}

enum TelemetryAttributeKey: String, Sendable {
    case syncType
    case outcome
    case errorClass
    case mailboxSizeBucket
    case taskType
}

struct TelemetryEvent: Equatable, Sendable {
    let name: TelemetryEventName
    let attributes: [TelemetryAttributeKey: String]
    let counters: [String: Int]

    init(
        name: TelemetryEventName,
        attributes: [TelemetryAttributeKey: String] = [:],
        counters: [String: Int] = [:]
    ) {
        self.name = name
        self.attributes = attributes
        self.counters = counters
    }
}

protocol TelemetryClient: Sendable {
    func record(_ event: TelemetryEvent) async
}

actor NoopTelemetryClient: TelemetryClient {
    static let shared = NoopTelemetryClient()

    private init() {}

    func record(_ event: TelemetryEvent) async {
        // Intentionally empty. Production integrations must keep the typed,
        // allowlisted event shape so message content and provider identifiers
        // never enter telemetry payloads.
    }
}
