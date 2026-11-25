import Foundation

/// One JSON file the user can share from the app: the app's version, the OS, every record
/// `DiagnosticsRecordStore` keeps, and the last background-task runs
/// (`BackgroundRunJournal`, iOS). It is made when the user shares it
/// (`DiagnosticsReportFile`), and goes only where the user sends it.
///
/// It names no account and holds no mail: the records are MetricKit payloads already cut
/// down to `DiagnosticsPayloadProjection`'s allowlist. Logs are not included: a shipped
/// build keeps warnings and errors only in the unified log, which holds identifiers the
/// redaction allowlist lets through, and a sysdiagnose is the way to collect it.
enum DiagnosticsReport {
    static let formatVersion = 1

    static func makeData(
        records recordContents: [(name: String, data: Data?)],
        appVersion: String?,
        appBuild: String?,
        osVersion: String,
        generatedAt: Date,
        backgroundRuns: [Any] = []
    ) -> Data {
        let records: [[String: Any]] = recordContents.map { name, data in
            var record: [String: Any] = ["file": name]
            if let data, let payload = try? JSONSerialization.jsonObject(with: data) {
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
            "records": records,
            "backgroundRuns": backgroundRuns
        ]
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }

    /// Writes the report into a folder of its own under `temporaryDirectory/DiagnosticsReport`,
    /// and removes the folders of earlier reports older than `staleReportAge`, so shares do
    /// not pile up, while two at once (or a share sheet still reading the last file) keep
    /// their own files.
    static func writeFile(
        store: DiagnosticsRecordStore,
        bundle: Bundle = .main,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) throws -> URL {
        let data = makeData(
            records: store.recordContents(),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            generatedAt: now,
            backgroundRuns: backgroundRunsForReport()
        )
        let parent = temporaryDirectory.appendingPathComponent("DiagnosticsReport", isDirectory: true)
        removeStaleReports(in: parent, now: now)
        let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let url = directory.appendingPathComponent("MushMail Diagnostics \(formatter.string(from: now)).json")
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// The background-task journal (`BackgroundRunJournal`) as JSON values. iOS only: the
    /// Mac has no background tasks.
    static func backgroundRunsForReport() -> [Any] {
        #if os(iOS)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(BackgroundRunJournal.shared.entries()),
              let runs = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return runs
        #else
        return []
        #endif
    }

    static let staleReportAge: TimeInterval = 10 * 60

    /// Removes the report folders in `parent` made more than `staleReportAge` ago. Only
    /// folders directly in `parent`, which this type alone writes.
    static func removeStaleReports(in parent: URL, now: Date) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for folder in folders {
            // A folder whose age cannot be read is treated as new: removing it could be
            // removing another share's file while it is read.
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            if now.timeIntervalSince(created) > staleReportAge {
                try? fileManager.removeItem(at: folder)
            }
        }
    }
}
