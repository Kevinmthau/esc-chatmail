import XCTest
@testable import esc_chatmail

final class LoggerConfigurationTests: XCTestCase {
    func testLogLevelParse_acceptsCommonValues() {
        XCTAssertEqual(LogLevel.parse(environmentValue: "debug"), .debug)
        XCTAssertEqual(LogLevel.parse(environmentValue: "INFO"), .info)
        XCTAssertEqual(LogLevel.parse(environmentValue: "warn"), .warning)
        XCTAssertEqual(LogLevel.parse(environmentValue: "error"), .error)
    }

    func testLogLevelParse_rejectsUnknownValues() {
        XCTAssertNil(LogLevel.parse(environmentValue: nil))
        XCTAssertNil(LogLevel.parse(environmentValue: "verbose"))
    }

    func testDiagnosticAreasParse_supportsCommaSeparatedAreas() {
        let areas = LogDiagnosticArea.parse(environmentValue: "startup, html-preview, pending_actions")

        XCTAssertEqual(areas, Set([.startup, .htmlPreview, .pendingActions]))
    }

    func testDiagnosticAreasParse_supportsAllShortcut() {
        let areas = LogDiagnosticArea.parse(environmentValue: "all")

        XCTAssertEqual(areas, Set(LogDiagnosticArea.allCases))
    }

    func testDiagnosticAreasFromEnvironment_usesConfiguredKey() {
        let areas = LoggerConfiguration.diagnosticAreas(
            from: [LogDiagnosticArea.environmentKey: "chat-view,conversation-rollups"]
        )

        XCTAssertEqual(areas, Set([.chatView, .conversationRollups]))
    }
}
