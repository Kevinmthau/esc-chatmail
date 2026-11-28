import XCTest

/// Pins from source what `EmailContentSection` asks the full-email pool for, because no test can
/// mount a chat row and watch the warm it schedules 200 ms later: a visible row warms the prepared
/// HTML through `warmVisibleRow` and never passes a width, so no off-screen WebView loads the
/// original's remote images and open pixels for mail the user has not opened
/// (architecture review 2026-11, `security-privacy#3`).
final class EmailContentSectionWarmSourceTests: XCTestCase {
    private let path = "esc-chatmail/Views/Components/EmailContent/EmailContentSection.swift"

    /// Revert-check: calling `fullEmailOpener.warm(…, width: <anything but nil>)` from the row's warm
    /// task, as it did with the screen width before, fails this.
    func testEmailContentSection_warmsVisibleRowsWithoutAWidth() throws {
        let source = try repositorySource(path)

        XCTAssertTrue(
            source.contains("await fullEmailOpener.warmVisibleRow("),
            "The visible-row warm goes through warmVisibleRow"
        )

        let calls = Self.calls(named: "fullEmailOpener.warm(", in: source)
        for call in calls {
            XCTAssertTrue(
                call.contains("width: nil"),
                "Every direct warm from a row passes no width: \(call)"
            )
        }
    }

    /// The text of each call of `prefix` up to its closing parenthesis.
    private static func calls(named prefix: String, in source: String) -> [String] {
        var calls: [String] = []
        var searchStart = source.startIndex
        while let range = source.range(of: prefix, range: searchStart..<source.endIndex) {
            var depth = 1
            var index = range.upperBound
            while index < source.endIndex, depth > 0 {
                switch source[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                index = source.index(after: index)
            }
            calls.append(String(source[range.lowerBound..<index]))
            searchStart = index
        }
        return calls
    }
}
