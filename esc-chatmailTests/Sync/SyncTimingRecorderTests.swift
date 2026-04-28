import XCTest
@testable import esc_chatmail

final class SyncTimingRecorderTests: XCTestCase {
    func testSummaryIncludesTotalOutcomeAndPhaseDetails() {
        var recorder = SyncTimingRecorder(syncType: "incremental", runStartedAt: 0)

        recorder.finish(
            SyncPhaseTimer(name: "historyCollection", startedAt: CFAbsoluteTimeGetCurrent() - 0.25),
            detail: "records=2"
        )

        let summary = recorder.summary(totalDuration: 1.5, outcome: "success")

        XCTAssertTrue(summary.contains("Sync timing [incremental] total=1.500s outcome=success"))
        XCTAssertTrue(summary.contains("historyCollection="))
        XCTAssertTrue(summary.contains("records=2"))
    }

    func testFormatDurationUsesMillisecondsPrecision() {
        XCTAssertEqual(SyncTimingRecorder.formatDuration(0.1234), "0.123s")
        XCTAssertEqual(SyncTimingRecorder.formatDuration(12), "12.000s")
    }
}
