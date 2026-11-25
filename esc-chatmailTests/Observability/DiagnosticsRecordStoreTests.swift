import XCTest
@testable import esc_chatmail

/// The MetricKit records kept on the device: capped, pruned oldest first, never touching a
/// file that is not the store's own (architecture review 2026-11, `observability-errors#1`).
final class DiagnosticsRecordStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsRecordStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // Revert-check: fails if `pruneLocked` stops removing the oldest files past
    // `maxRecords`, or removes the newest instead.
    func testRecord_pastTheCountCap_keepsTheNewest() throws {
        let clock = StoreTestClock()
        let store = DiagnosticsRecordStore(directory: directory, maxRecords: 3, now: { clock.next() })

        let written = (0..<5).compactMap { _ in store.record(kind: .diagnostic, payloadJSON: hangPayload()) }

        XCTAssertEqual(written.count, 5)
        XCTAssertEqual(store.recordURLs().map(\.lastPathComponent), written.suffix(3).map(\.lastPathComponent))
    }

    func testRecord_pastTheByteCap_dropsOldestUntilUnder() throws {
        let clock = StoreTestClock()
        let size = try XCTUnwrap(DiagnosticsPayloadProjection.project(kind: .diagnostic, json: hangPayload())).count
        let store = DiagnosticsRecordStore(directory: directory, maxRecords: 100, maxBytes: size * 2, now: { clock.next() })

        let written = (0..<4).compactMap { _ in store.record(kind: .diagnostic, payloadJSON: hangPayload()) }

        XCTAssertEqual(store.recordURLs().map(\.lastPathComponent), written.suffix(2).map(\.lastPathComponent))
    }

    // Revert-check: fails if `ownFilesLocked` stops filtering on `filePrefix`: pruning
    // would then remove a file the store did not write.
    func testPrune_leavesForeignFilesAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("aaa-someone-elses.json")
        try Data("{}".utf8).write(to: foreign)
        let clock = StoreTestClock()
        let store = DiagnosticsRecordStore(directory: directory, maxRecords: 1, now: { clock.next() })

        store.record(kind: .diagnostic, payloadJSON: hangPayload())
        store.record(kind: .diagnostic, payloadJSON: hangPayload())

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertEqual(store.recordURLs().count, 1)
    }

    // Revert-check: fails if `pruneLocked` may remove the file just written: with the
    // clock set back, the new record's name sorts first and was pruned at once.
    func testRecord_afterTheClockWentBack_keepsTheNewRecord() throws {
        let clock = StoreTestClock()
        let store = DiagnosticsRecordStore(directory: directory, maxRecords: 2, now: { clock.next() })
        store.record(kind: .diagnostic, payloadJSON: hangPayload())
        store.record(kind: .diagnostic, payloadJSON: hangPayload())
        clock.setBack(by: 3600)

        let written = try XCTUnwrap(store.record(kind: .diagnostic, payloadJSON: hangPayload()))

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(store.recordURLs().count, 2)
    }

    func testRecord_largerThanTheByteCap_isNotWritten() {
        let store = DiagnosticsRecordStore(directory: directory, maxBytes: 10)

        XCTAssertNil(store.record(kind: .diagnostic, payloadJSON: hangPayload()))
        XCTAssertTrue(store.recordURLs().isEmpty)
    }

    func testRecord_writesTheProjection_notThePayload() throws {
        var payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: hangPayload()) as? [String: Any])
        payload["unlisted"] = "someone@example.com"
        let store = DiagnosticsRecordStore(directory: directory)

        let url = try XCTUnwrap(store.record(kind: .diagnostic, payloadJSON: try JSONSerialization.data(withJSONObject: payload)))

        let stored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(stored.contains("someone@example.com"))
        XCTAssertTrue(stored.contains("hangDiagnostics"))
    }

    func testReport_holdsEveryRecordAndNoAccount() throws {
        let store = DiagnosticsRecordStore(directory: directory)
        store.record(kind: .diagnostic, payloadJSON: hangPayload())
        let unreadable = directory.appendingPathComponent("mx-999999999999999-diagnostic-broken.json")
        try Data("not json".utf8).write(to: unreadable)

        let data = DiagnosticsReport.makeData(
            records: store.recordContents(),
            appVersion: "1.0",
            appBuild: "612",
            osVersion: "iOS 27.0",
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(report["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertNotNil(records[0]["payload"])
        XCTAssertEqual(records[1]["unreadable"] as? Bool, true)
        XCTAssertEqual(report["appBuild"] as? String, "612")
        XCTAssertEqual(Set(report.keys), ["formatVersion", "generatedAt", "appVersion", "appBuild", "os", "records"])
    }

    private func hangPayload() -> Data {
        let payload: [String: Any] = [
            "timeStampBegin": "2026-11-24 10:00:00",
            "timeStampEnd": "2026-11-24 10:00:00",
            "hangDiagnostics": [[
                "version": "1.0.0",
                "diagnosticMetaData": ["hangDuration": "3 sec", "appBuildVersion": "612"],
                "callStackTree": ["callStackPerThread": false, "callStacks": []]
            ]]
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}

/// A clock a second further on at each call, so the store's file names sort as written.
/// `@unchecked Sendable`: `lock` guards `seconds`.
private final class StoreTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_800_000_000

    func setBack(by interval: TimeInterval) {
        lock.withLock { seconds -= interval }
    }

    func next() -> Date {
        lock.withLock {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
    }
}
