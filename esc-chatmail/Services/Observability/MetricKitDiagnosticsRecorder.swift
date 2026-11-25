#if os(iOS)
import Foundation
import MetricKit

/// Subscribes to MetricKit and hands each payload to `DiagnosticsRecordStore`
/// (architecture review 2026-11, `observability-errors#1`).
///
/// MetricKit delivers a diagnostic payload (crash, hang, CPU or disk-write exception, slow
/// launch) on the launch after the event, and the daily metric payload (exits by reason,
/// including the background ones nothing else records) about once a day. Both arrive on a
/// queue of MetricKit's; the file work goes to a utility queue of this recorder's and is
/// never awaited, so a cold background launch pays nothing for it.
///
/// iOS only for now: on the Mac the system's crash reports and the unified log already
/// hold what this would, and the Mac app has no background tasks to be killed in.
///
/// Registered once, in `App.init`, and never in the unit-test host (its container is the
/// real app's on the Mac, and its tests must not write the app's files); the position is
/// pinned from source (`MetricKitRegistrationSourceTests`).
///
/// `@unchecked Sendable`: every stored property is immutable, and `DiagnosticsRecordStore`
/// serializes its own file work.
final class MetricKitDiagnosticsRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnosticsRecorder(store: .shared)

    private let store: DiagnosticsRecordStore
    private let queue = DispatchQueue(label: "com.esc-chatmail.MetricKitDiagnosticsRecorder", qos: .utility)

    init(store: DiagnosticsRecordStore) {
        self.store = store
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let jsons = payloads.map { $0.jsonRepresentation() }
        let summary = payloads.map(Self.summary).joined(separator: "; ")
        // One line per delivery, at warning so a Release build keeps it: counts only.
        Log.warning("MetricKit delivered \(payloads.count) diagnostic payload(s): \(summary)", category: .performance)
        queue.async { [store] in
            for json in jsons {
                store.record(kind: .diagnostic, payloadJSON: json)
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let jsons = payloads.map { $0.jsonRepresentation() }
        Log.info("MetricKit delivered \(payloads.count) metric payload(s)", category: .performance)
        queue.async { [store] in
            for json in jsons {
                store.record(kind: .metrics, payloadJSON: json)
            }
        }
    }

    /// How many of each kind a payload holds, e.g. "crash 1, hang 2".
    private static func summary(of payload: MXDiagnosticPayload) -> String {
        let counts: [(String, Int)] = [
            ("crash", payload.crashDiagnostics?.count ?? 0),
            ("hang", payload.hangDiagnostics?.count ?? 0),
            ("cpu", payload.cpuExceptionDiagnostics?.count ?? 0),
            ("diskWrite", payload.diskWriteExceptionDiagnostics?.count ?? 0),
            ("launch", payload.appLaunchDiagnostics?.count ?? 0)
        ]
        let parts = counts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }
}
#endif
