#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import esc_chatmail

/// The height of the row above the iPhone's reply field (`ChatReplyBarHeaderRow`), measured
/// on a mounted row.
///
/// The row names a reply's recipients where the chat's title does not, and both how many
/// there are and how long each address is are the sender's to choose. Its height is part of
/// the composer's, which is the transcript's bottom inset, so a row as tall as its text let
/// one message's Reply-To header take the screen.
///
/// HONEST SCOPE: these hand the row a header and whether its quote row is open, and measure
/// it. Nothing here taps the row: that a tap opens it is pinned from source
/// (`ReplyIndicatorWholeLabelSourceTests`), and that `ChatReplyBar` closes it again when the
/// header changes is not pinned at all. Nothing has been seen in the app: not the row
/// scrolling, not the mark that says it opens. This suite is iOS-only; the Mac draws
/// `MacReplyIndicator`.
@MainActor
final class ChatReplyBarHeaderRowTests: XCTestCase {
    private static let rowWidth: CGFloat = 390
    /// The row's padding above and below its text.
    private static let verticalPadding: CGFloat = 12

    /// Forty addresses of sixty characters: some forty-five lines of the caption font.
    private static let manyLongRecipients = (1...40)
        .map { "billing.department.number.\(String(format: "%02d", $0))@accounts.subsidiary.example.com" }
        .joined(separator: ", ")

    // MARK: - A row of text

    /// Revert-check: deleting `.frame(maxHeight: ReplyIndicatorPolicy.wrappingLabelMaxHeight)`
    /// from `ChatReplyBarHeaderRow.boundedLabel`, or drawing the text there with no
    /// `ViewThatFits` and scroll view around it, makes this fail: the row is then as tall as
    /// its text, several times the limit.
    func testRecipientsRow_headerNamingManyLongAddresses_isNoTallerThanTheLimit() throws {
        let label = "To: \(Self.manyLongRecipients)"
        let limit = ReplyIndicatorPolicy.wrappingLabelMaxHeight + Self.verticalPadding

        for header in [
            ReplyIndicatorPolicy.Header.addressedTo(label: "To: a…b@example.com +39 more", unabridgedLabel: label),
            .recoveredEnvelope(label: "Replying to: \(Self.manyLongRecipients)")
        ] {
            let row = try measureRow(header)

            XCTAssertLessThanOrEqual(row.height, limit + 0.5, "\(header)")
            // And it uses the room it is allowed, with the rest of the text a scroll away:
            // nothing of it is cut off.
            XCTAssertGreaterThan(row.height, limit - 1, "\(header)")
            XCTAssertTrue(row.scrolls, "\(header)")
        }
        // The text really is taller than the limit, or the two assertions above say nothing.
        XCTAssertGreaterThan(try plainTextHeight(label), limit * 3)
    }

    /// Text that fits is drawn as it always was: at its own height, and with no scroll view
    /// around it.
    ///
    /// Revert-check: deleting the `.fixedSize(horizontal: false, vertical: true)` from
    /// `ChatReplyBarHeaderRow.boundedLabel`, which is how the row was first written, makes
    /// the height fail: the frame with the limit is then as tall as the limit whatever it
    /// holds (132 points for a row whose text is 26). Drawing the text in a scroll view
    /// whatever its height (drop the first choice of the `ViewThatFits` there) leaves the
    /// height as it is, and makes the other assertion fail.
    func testRecipientsRow_ordinaryLabels_areAsTallAsTheirText_andDoNotScroll() throws {
        let severalLines = "To: " + (1...5).map { "person.number.\($0)@example.com" }.joined(separator: ", ")

        for label in ["To: sam@example.com", severalLines] {
            let row = try measureRow(.addressedTo(label: label))

            XCTAssertEqual(row.height, try plainTextHeight(label), accuracy: 0.5, label)
            XCTAssertFalse(row.scrolls, label)
        }
        XCTAssertGreaterThan(try plainTextHeight(severalLines), try plainTextHeight("To: sam@example.com") + 5)
    }

    /// The row with its own `To:` line draws the whole label, not the short one.
    ///
    /// Revert-check: drawing `label` in the `.addressedTo` case of
    /// `ChatReplyBarHeaderRow.body`, in place of `ReplyIndicatorPolicy.wholeLabel(…)`, makes
    /// this fail: the row is then one line, the short label's.
    func testRecipientsRow_headerWithAnUnabridgedLabel_drawsThatLabel() throws {
        let whole = "To: " + (1...5).map { "person.number.\($0)@example.com" }.joined(separator: ", ")

        XCTAssertEqual(
            try rowHeight(.addressedTo(label: "To: a@example.com", unabridgedLabel: whole)),
            try plainTextHeight(whole),
            accuracy: 0.5
        )
    }

    // MARK: - The quote row

    /// Revert-check: drawing `Text(row.text)` on one line whatever `row.wraps` says, in
    /// `ChatReplyBarHeaderRow.quoteRow`, makes the first assertion fail; so does a
    /// `ReplyIndicatorPolicy.quoteRow` that never opens. Deleting the `.frame(maxHeight:)`
    /// from `boundedLabel` makes the second fail.
    func testQuoteRow_opened_growsToItsWholeLabel_andNoTallerThanTheLimit() throws {
        let short = "Replying to a…b@example.com, c…d@example.com +3 more: Invoice"
        let whole = "Replying to " + (1...5).map { "person.number.\($0)@example.com" }.joined(separator: ", ") + ": Invoice"
        let closed = try rowHeight(.replyingTo(label: short, unabridgedLabel: whole), isQuoteRowOpen: false)

        let opened = try rowHeight(.replyingTo(label: short, unabridgedLabel: whole), isQuoteRowOpen: true)
        let openedOnManyRecipients = try rowHeight(
            .replyingTo(label: short, unabridgedLabel: "Replying to \(Self.manyLongRecipients): Invoice"),
            isQuoteRowOpen: true
        )

        XCTAssertGreaterThan(opened, closed + 10)
        XCTAssertLessThanOrEqual(
            openedOnManyRecipients,
            ReplyIndicatorPolicy.wrappingLabelMaxHeight + Self.verticalPadding + 0.5
        )
        XCTAssertGreaterThan(openedOnManyRecipients, opened)
    }

    /// The mark that says a row opens adds nothing to its height, and the ordinary chat's
    /// row, which opens for nobody, stays one line whatever the bar's state says.
    ///
    /// Revert-check: making an open row from `label` in `ReplyIndicatorPolicy.quoteRow` where
    /// the header carries no unabridged label makes the second assertion fail: the long
    /// subject then wraps.
    func testQuoteRow_closed_andTheRowThatNeverOpens_areOneHeight() throws {
        let ordinary = try rowHeight(.replyingTo(label: "Replying to: Lunch?"), isQuoteRowOpen: false)
        let longSubject = "Replying to: " + String(repeating: "a very long subject ", count: 12)

        XCTAssertEqual(
            try rowHeight(
                .replyingTo(label: "Replying to sam@example.com: Lunch?", unabridgedLabel: "Replying to sam@example.com: Lunch?"),
                isQuoteRowOpen: false
            ),
            ordinary,
            accuracy: 0.5
        )
        XCTAssertEqual(
            try rowHeight(.replyingTo(label: longSubject), isQuoteRowOpen: true),
            ordinary,
            accuracy: 0.5
        )
    }

    // MARK: - Measuring

    private func rowHeight(_ header: ReplyIndicatorPolicy.Header, isQuoteRowOpen: Bool = false) throws -> CGFloat {
        try measureRow(header, isQuoteRowOpen: isQuoteRowOpen).height
    }

    /// The row's height at the width of a phone, and whether its text is in a scroll view:
    /// SwiftUI's is a `UIScrollView` in the hosting view, and a row with none has none.
    private func measureRow(
        _ header: ReplyIndicatorPolicy.Header,
        isQuoteRowOpen: Bool = false
    ) throws -> (height: CGFloat, scrolls: Bool) {
        let host = try mountInTestWindow(
            ChatReplyBarHeaderRow(
                header: header,
                allowsDraftMutation: true,
                isQuoteRowOpen: .constant(isQuoteRowOpen),
                onDropQuote: {},
                onClearUnavailableTarget: {}
            )
            .frame(width: Self.rowWidth)
        )
        return (
            host.sizeThatFits(in: CGSize(width: Self.rowWidth, height: 2_000)).height,
            Self.containsScrollView(host.view)
        )
    }

    private static func containsScrollView(_ view: UIView) -> Bool {
        view is UIScrollView || view.subviews.contains(where: containsScrollView)
    }

    /// The height of `label` drawn as a row of text was before it had a limit: the text in
    /// the caption font, wrapped at the row's width, inside the row's padding.
    private func plainTextHeight(_ label: String) throws -> CGFloat {
        let host = try mountInTestWindow(
            Text(label)
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(width: Self.rowWidth)
        )
        return host.sizeThatFits(in: CGSize(width: Self.rowWidth, height: 20_000)).height
    }
}
#endif
