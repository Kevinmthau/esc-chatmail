import XCTest
@testable import esc_chatmail

final class SyncTimingRecorderTests: XCTestCase {
    func testSummaryIncludesTotalOutcomeAndPhaseDetails() {
        var recorder = SyncTimingRecorder(syncType: "incremental", runStartedAt: 0)

        recorder.finish(
            SyncPhaseTimer(name: "historyCollection", startedAt: CFAbsoluteTimeGetCurrent() - 0.25),
            detail: "records=2"
        )

        let summary = recorder.summary(
            totalDuration: 1.5,
            outcome: .incrementalSuccess(newMessages: 3, labelRecords: 2, continuation: false, warnings: true)
        )

        XCTAssertTrue(summary.contains(
            "Sync timing [incremental] total=1.500s outcome=success newMessages=3 labelRecords=2 continuation=false warnings=true"
        ), summary)
        XCTAssertTrue(summary.contains("historyCollection="))
        XCTAssertTrue(summary.contains("records=2"))
    }

    /// The summary is logged through `Log`, which publishes the finished string, so a
    /// failed run names the error's domain and code and never its text: a provider
    /// error's description can carry request details (architecture review 2026-11,
    /// observability-errors#5, security-privacy#4). Six call sites used to interpolate
    /// `error.localizedDescription` into a `String` outcome, past `LogRedactionTests`'
    /// scan, which reads `Log.` calls only.
    ///
    /// Revert-check: rendering `SyncRunOutcome.failed` from the error's
    /// `localizedDescription` instead of `Log.redact(error:)` fails this. The `String`
    /// outcome parameter cannot come back without every call site failing to compile.
    func testSummary_failedOutcome_namesTheErrorsDomainAndCode_neverItsDescription() {
        let recorder = SyncTimingRecorder(syncType: "initial", runStartedAt: 0)
        let error = NSError(
            domain: "SensitiveDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "token=secret for jane.doe@example.com"]
        )

        let summary = recorder.summary(totalDuration: 0.25, outcome: .failed(error))

        XCTAssertEqual(summary, "Sync timing [initial] total=0.250s outcome=failed error=SensitiveDomain#42")
        XCTAssertFalse(summary.contains("secret"))
        XCTAssertFalse(summary.contains("jane.doe"))
        XCTAssertFalse(summary.contains(error.localizedDescription))
    }

    /// An `APIError` is named by its case, as `Log.redact(error:)` names it.
    func testSummary_failedAPIErrorOutcome_namesTheCase() {
        let recorder = SyncTimingRecorder(syncType: "incremental", runStartedAt: 0)

        let summary = recorder.summary(totalDuration: 2, outcome: .failed(APIError.timeout))

        XCTAssertTrue(summary.hasSuffix("outcome=failed error=APIError.timeout"), summary)
    }

    func testSummaryText_everyOutcome_isBuiltFromCountsAndFlags() {
        XCTAssertEqual(SyncRunOutcome.initialSuccess(messages: 5, conversations: 2, warnings: false).summaryText,
                       "success messages=5 conversations=2 warnings=false")
        XCTAssertEqual(SyncRunOutcome.initialFallbackDeferred.summaryText, "initialFallback deferred=true")
        XCTAssertEqual(SyncRunOutcome.initialFallback(incomplete: true).summaryText, "initialFallback incomplete=true")
        XCTAssertEqual(SyncRunOutcome.historyRecoveryDeferred.summaryText, "historyRecovery deferred=true")
        XCTAssertEqual(SyncRunOutcome.historyRecovery(warnings: true).summaryText, "historyRecovery warnings=true")
    }

    func testFormatDurationUsesMillisecondsPrecision() {
        XCTAssertEqual(SyncTimingRecorder.formatDuration(0.1234), "0.123s")
        XCTAssertEqual(SyncTimingRecorder.formatDuration(12), "12.000s")
    }
}
