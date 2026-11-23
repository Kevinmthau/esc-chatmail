import XCTest

/// Every SwiftSoup parse of a string goes through `EmailDOMParseAdmission`.
/// A parse anywhere else would build a sender-chosen depth on the caller's
/// stack, which is the crash the gate exists to stop, and nothing at run time
/// would say so.
final class EmailDOMParseAdmissionSourceTests: XCTestCase {
    private static let gatePath = "esc-chatmail/Services/EmailDOM/EmailDOMParseAdmission.swift"

    /// The entry points that turn a string into a tree.
    private static let parseEntryPoints = [
        "SwiftSoup.parse(",
        "SwiftSoup.parseBodyFragment(",
        "SwiftSoup.clean(",
        "SwiftSoup.isValid(",
        "Parser.parse(",
        "Parser.parseFragment(",
        "Parser.parseBodyFragment(",
        "Parser.parseXmlFragment(",
        "Parser.htmlParser(",
        "Parser.xmlParser(",
    ]

    func testSwiftSoupParsing_happensOnlyInTheAdmissionGate() throws {
        let paths = try repositorySwiftFilePaths(under: "esc-chatmail")
        XCTAssertTrue(paths.contains(Self.gatePath))
        XCTAssertGreaterThan(paths.count, 100)

        // `ReservationSummaryParser.parse(` is not SwiftSoup's.
        let patterns = try Self.parseEntryPoints.map { entryPoint in
            try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: entryPoint))
        }
        for path in paths where path != Self.gatePath {
            let source = try repositorySource(path)
            let range = NSRange(source.startIndex..., in: source)
            for (entryPoint, pattern) in zip(Self.parseEntryPoints, patterns) {
                XCTAssertNil(pattern.firstMatch(in: source, range: range), "\(path) calls \(entryPoint)")
            }
        }
    }

    func testAdmissionGate_stillParsesThroughSwiftSoup() throws {
        let source = try repositorySource(Self.gatePath)
        XCTAssertTrue(source.contains("SwiftSoup.parse("))
        XCTAssertTrue(source.contains("SwiftSoup.parseBodyFragment("))
        XCTAssertTrue(source.contains("Parser.parseFragment("))
    }
}
