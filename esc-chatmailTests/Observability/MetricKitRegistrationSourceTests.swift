import XCTest

/// `App.init` runs under no test, so where it starts the MetricKit recorder is pinned
/// from source (architecture review 2026-11, `observability-errors#1`).
final class MetricKitRegistrationSourceTests: XCTestCase {
    // Revert-check: fails if the recorder is started outside the `!isRunningUnitTests`
    // block (a test host would subscribe and write the app's files), outside `#if os(iOS)`,
    // or ahead of the Mac test-host guard.
    func testRecorder_isStartedInsideTheNonTestBlock_onIOSOnly() throws {
        let source = try repositorySource("esc-chatmail/App/esc_chatmailApp.swift")
        let guardCall = try XCTUnwrap(source.range(of: "MacUnitTestHostGuard.exitUnlessPermitted()"))
        let nonTestBlock = try XCTUnwrap(source.range(of: "        if !isRunningUnitTests {\n"))
        let blockEnd = try XCTUnwrap(source.range(of: "\n        }\n", range: nonTestBlock.upperBound..<source.endIndex))
        let start = try XCTUnwrap(source.range(of: "MetricKitDiagnosticsRecorder.shared.start()"))

        XCTAssertLessThan(guardCall.lowerBound, nonTestBlock.lowerBound)
        XCTAssertLessThan(nonTestBlock.upperBound, start.lowerBound)
        XCTAssertLessThan(start.upperBound, blockEnd.lowerBound)
        let iOSOpen = try XCTUnwrap(source.range(of: "#if os(iOS)", options: .backwards, range: nonTestBlock.upperBound..<start.lowerBound))
        let between = source[iOSOpen.upperBound..<start.lowerBound]
        XCTAssertFalse(between.contains("#endif"), "The start must be inside an #if os(iOS)")
        XCTAssertEqual(source.components(separatedBy: "MetricKitDiagnosticsRecorder.shared.start()").count - 1, 1)
    }

    func testShareDiagnostics_isOfferedByTheIOSListOnly() throws {
        let list = try repositorySource("esc-chatmail/Views/Main/ConversationListView.swift")
        XCTAssertTrue(list.contains("showsDiagnosticsShare: AppPlatform.current == .iOS"))
        let sidebar = try repositorySource("esc-chatmail/Platform/MacConversationSidebar.swift")
        XCTAssertFalse(sidebar.contains("showsDiagnosticsShare"))
    }
}
