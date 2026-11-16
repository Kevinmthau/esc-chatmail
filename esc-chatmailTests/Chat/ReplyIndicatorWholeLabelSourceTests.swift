import XCTest
@testable import esc_chatmail

/// Pins, from the source text, that the rows above the reply field keep the whole label
/// within reach where they draw the short one.
///
/// `ReplyIndicatorPolicy.header` shortens a long address and, beside a quote, counts the
/// recipients after the second. That row is where the user learns that a reply goes to people
/// the chat's title does not name, and a cut address can be someone else's, so the header
/// also carries the label whole (`unabridgedLabel`). It is only of use if the views take it:
/// the iPhone's one-line row gives it to VoiceOver and opens on a tap to draw it, and the
/// Mac's capsule shows it as its tooltip.
///
/// HONEST SCOPE: this reads the files' text. No test here asks a mounted row for its tooltip
/// or its accessibility label, and none taps a row; none of it has been seen or heard in the
/// app. `ChatReplyBarTests` pins what the header carries, what `wholeLabel` returns and what
/// an opened row draws, and `ChatReplyBarHeaderRowTests` mounts the iPhone's row and measures
/// it, which is where the row with its own `To:` line is pinned to draw the whole label.
final class ReplyIndicatorWholeLabelSourceTests: XCTestCase {
    private static let headerRowPath = "esc-chatmail/Views/Compose/ChatReplyBarHeaderRow.swift"

    /// Revert-check: deleting the `.accessibilityLabel(…)` from the one-line label of
    /// `ChatReplyBarHeaderRow.quoteRow` makes this fail.
    func testBar_quoteRow_givesVoiceOverTheWholeLabel() throws {
        let code = try codeLines(Self.headerRowPath)
        let label = try XCTUnwrap(code.firstIndex(of: "Text(row.text)"))
        let nextView = try XCTUnwrap(code[(label + 1)...].firstIndex { !$0.hasPrefix(".") })
        XCTAssertTrue(
            code[(label + 1)..<nextView].contains(
                ".accessibilityLabel(ReplyIndicatorPolicy.wholeLabel(label, unabridged: unabridgedLabel))"
            ),
            "The one-line quote row no longer gives VoiceOver the whole label"
        )
    }

    /// A tap is the only way a sighted user of the iPhone sees a cut address whole, and no
    /// test taps the row.
    ///
    /// Revert-check: deleting the `.gesture(…)` from `ChatReplyBarHeaderRow.quoteRow`, or
    /// attaching it whatever `row.opens` says, makes the first assertion fail; deleting the
    /// mark that says the row opens makes the second fail.
    func testBar_quoteRowThatOpens_takesATap_andShowsThatItDoes() throws {
        let code = try codeLines(Self.headerRowPath)

        XCTAssertTrue(
            code.contains(".gesture(row.opens ? TapGesture().onEnded { isQuoteRowOpen.toggle() } : nil)"),
            "A tap no longer opens the quote row"
        )
        let mark = try XCTUnwrap(code.firstIndex(of: "if row.opens {"))
        XCTAssertEqual(
            code[mark + 1],
            "Image(systemName: row.wraps ? \"chevron.up\" : \"chevron.down\")"
        )
    }

    /// Text that wraps is drawn with its addresses marked, so a line break adds no hyphen to
    /// one (`ReplyIndicatorPolicy.wrappingLabel`). No test asks the text where its lines
    /// break, so that the rows draw the marked label is pinned here.
    ///
    /// Revert-check: drawing `Text(text)` in `ChatReplyBarHeaderRow.labelText` makes the first
    /// assertion fail; deleting the `.accessibilityLabel(text)` under it makes the second
    /// fail, and VoiceOver is then left with text marked as being in no language.
    func testBar_textThatWraps_isDrawnWithItsAddressesMarked() throws {
        let code = try codeLines(Self.headerRowPath)
        let label = try XCTUnwrap(code.firstIndex {
            $0.hasPrefix("private func labelText(_ text: String, fillsWidth: Bool)")
        })

        XCTAssertEqual(code[label + 1], "Text(ReplyIndicatorPolicy.wrappingLabel(text))")
        XCTAssertEqual(code[label + 2], ".accessibilityLabel(text)")
        // And both rows of text, and the opened quote row, are drawn through it.
        XCTAssertEqual(code.filter { $0.hasPrefix("labelText(text, fillsWidth: fillsWidth)") }.count, 2)
        XCTAssertEqual(code.filter { $0.hasPrefix("Text(") && $0 != "Text(row.text)" }, [
            "Text(\"Original reply target unavailable\")",
            "Text(ReplyIndicatorPolicy.wrappingLabel(text))"
        ])
    }

    /// An opened row is closed again when the header changes: it was opened on one reply's
    /// recipients, and the next row has others.
    ///
    /// Revert-check: deleting the `.onChange(of: header)` from `ChatReplyBar.bar` makes this
    /// fail.
    func testBar_headerChanges_closeTheQuoteRow() throws {
        let code = try codeLines("esc-chatmail/Views/Compose/ChatReplyBar.swift")
        let change = try XCTUnwrap(code.firstIndex(of: ".onChange(of: header) { _, _ in"))

        XCTAssertEqual(code[change + 1], "isQuoteRowOpen = false")
        XCTAssertTrue(code.contains("isQuoteRowOpen: $isQuoteRowOpen,"), "The bar no longer hands the row its state")
    }

    /// CI compiles the Mac build but runs no Mac test, so the capsule is pinned here.
    ///
    /// Revert-check: deleting `.help(whole)` or `.accessibilityLabel(whole)` from
    /// `MacReplyIndicator.oneLineLabel`, computing `whole` as `label`, or drawing either of
    /// the two recipient rows with a bare `Text(label)`, makes this fail.
    func testMacCapsule_recipientRows_showTheWholeLabelAsTooltip() throws {
        let code = try codeLines("esc-chatmail/Platform/MacReplyIndicator.swift")

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
    private func codeLines(_ path: String) throws -> [String] {
        try repositorySource(path)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }
}
