import XCTest
@testable import esc_chatmail

/// Pins, from the source text, that the rows above the reply field keep the whole label
/// within reach where they draw the short one.
///
/// `ReplyIndicatorPolicy.header` shortens a long address and, beside a quote, counts the
/// recipients after the second. That row is where the user learns that a reply goes to people
/// the chat's title does not name, and a cut address can be someone else's, so the header
/// also carries the label whole (`unabridgedLabel`). It is only of use if the views take it:
/// the bar's own row, which wraps, draws it; a one-line row gives it to VoiceOver; and the
/// Mac's capsule shows it as its tooltip.
///
/// HONEST SCOPE: this reads the two files' text. No test here asks a mounted row for its
/// tooltip or its accessibility label, and neither has been seen or heard in the app.
/// `ChatReplyBarTests` pins what the header carries and what `wholeLabel` returns.
final class ReplyIndicatorWholeLabelSourceTests: XCTestCase {
    /// Revert-check: drawing `label` in `ChatReplyBar.bar`'s `.addressedTo` case, in place of
    /// `ReplyIndicatorPolicy.wholeLabel(label, unabridged: unabridgedLabel)`, makes this fail.
    func testBar_ownRowOfRecipients_drawsTheWholeLabel() throws {
        let code = try appCode("Views/Compose/ChatReplyBar.swift")
        let ownRow = try XCTUnwrap(code.firstIndex(of: "case .addressedTo(let label, let unabridgedLabel):"))
        let nextCase = try XCTUnwrap(code[(ownRow + 1)...].firstIndex { $0.hasPrefix("case ") })
        XCTAssertEqual(
            Array(code[(ownRow + 1)..<nextCase]),
            ["wrappingRow(ReplyIndicatorPolicy.wholeLabel(label, unabridged: unabridgedLabel))"]
        )
    }

    /// Revert-check: deleting the `.accessibilityLabel(…)` from the label of
    /// `ChatReplyBar.replyingToIndicator` makes this fail.
    func testBar_quoteRow_givesVoiceOverTheWholeLabel() throws {
        let code = try appCode("Views/Compose/ChatReplyBar.swift")
        let indicator = try XCTUnwrap(code.firstIndex {
            $0.hasPrefix("private func replyingToIndicator(label: String, unabridgedLabel: String?)")
        })
        let label = try XCTUnwrap(code[indicator...].firstIndex(of: "Text(label)"))
        let nextView = try XCTUnwrap(code[(label + 1)...].firstIndex { !$0.hasPrefix(".") })
        XCTAssertTrue(
            code[(label + 1)..<nextView].contains(
                ".accessibilityLabel(ReplyIndicatorPolicy.wholeLabel(label, unabridged: unabridgedLabel))"
            ),
            "The one-line quote row no longer gives VoiceOver the whole label"
        )
    }

    /// CI compiles the Mac build but runs no Mac test, so the capsule is pinned here.
    ///
    /// Revert-check: deleting `.help(whole)` or `.accessibilityLabel(whole)` from
    /// `MacReplyIndicator.oneLineLabel`, computing `whole` as `label`, or drawing either of
    /// the two recipient rows with a bare `Text(label)`, makes this fail.
    func testMacCapsule_recipientRows_showTheWholeLabelAsTooltip() throws {
        let code = try appCode("Platform/MacReplyIndicator.swift")

        let helper = try XCTUnwrap(code.firstIndex {
            $0.hasPrefix("private func oneLineLabel(_ label: String, unabridgedLabel: String?)")
        })
        let helperEnd = try XCTUnwrap(code[helper...].firstIndex(of: "}"))
        let body = Array(code[(helper + 1)..<helperEnd])
        XCTAssertEqual(body.first, "let whole = ReplyIndicatorPolicy.wholeLabel(label, unabridged: unabridgedLabel)")
        XCTAssertTrue(body.contains(".help(whole)"), "The capsule's label has no tooltip")
        XCTAssertTrue(body.contains(".accessibilityLabel(whole)"), "VoiceOver is not given the whole label")

        for row in ["case .replyingTo(let label, let unabridgedLabel):", "case .addressedTo(let label, let unabridgedLabel):"] {
            let start = try XCTUnwrap(code.firstIndex(of: row), row)
            let nextCase = try XCTUnwrap(code[(start + 1)...].firstIndex { $0.hasPrefix("case ") })
            XCTAssertTrue(
                code[(start + 1)..<nextCase].contains("oneLineLabel(label, unabridgedLabel: unabridgedLabel)"),
                "\(row) no longer draws its label through oneLineLabel"
            )
        }
    }

    /// The file's lines, trimmed, without its comment lines.
    private func appCode(_ path: String) throws -> [String] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Chat
            .deletingLastPathComponent() // esc-chatmailTests
            .deletingLastPathComponent() // repo root
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("esc-chatmail").appendingPathComponent(path),
            encoding: .utf8
        )
        return source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }
}
