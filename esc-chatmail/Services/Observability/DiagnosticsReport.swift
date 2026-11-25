import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One JSON file the user can share from the app: the app's version, the OS, and every
/// record `DiagnosticsRecordStore` keeps. It is made when the user shares it
/// (`DiagnosticsReportFile`), and goes only where the user sends it.
///
/// It names no account and holds no mail: the records are MetricKit payloads already cut
/// down to `DiagnosticsPayloadProjection`'s allowlist. Logs are not included: a shipped
/// build keeps warnings and errors only in the unified log, which holds identifiers the
/// redaction allowlist lets through, and a sysdiagnose is the way to collect it.
enum DiagnosticsReport {
    static let formatVersion = 1

    static func makeData(
        recordURLs: [URL],
        appVersion: String?,
        appBuild: String?,
        osVersion: String,
        generatedAt: Date
    ) -> Data {
        let records: [[String: Any]] = recordURLs.map { url in
            var record: [String: Any] = ["file": url.lastPathComponent]
            if let data = try? Data(contentsOf: url),
               let payload = try? JSONSerialization.jsonObject(with: data) {
                record["payload"] = payload
            } else {
                record["unreadable"] = true
            }
            return record
        }
        let report: [String: Any] = [
            "formatVersion": formatVersion,
            "generatedAt": ISO8601DateFormatter().string(from: generatedAt),
            "appVersion": appVersion ?? "unknown",
            "appBuild": appBuild ?? "unknown",
            "os": osVersion,
            "records": records
        ]
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }

    /// Writes the report into a directory of its own under `temporaryDirectory`.
    static func writeFile(
        store: DiagnosticsRecordStore,
        bundle: Bundle = .main,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) throws -> URL {
        let data = makeData(
            recordURLs: store.recordURLs(),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            generatedAt: now
        )
        let directory = temporaryDirectory
            .appendingPathComponent("DiagnosticsReport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let url = directory.appendingPathComponent("MushMail Diagnostics \(formatter.string(from: now)).json")
        try data.write(to: url, options: [.atomic])
        return url
    }
}

/// What the Share Diagnostics item hands the share sheet: the report, made only when the
/// user picks where to send it.
struct DiagnosticsReportFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { _ in
            SentTransferredFile(try DiagnosticsReport.writeFile(store: .shared))
        }
    }
}
