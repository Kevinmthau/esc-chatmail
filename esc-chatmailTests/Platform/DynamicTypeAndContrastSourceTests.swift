import XCTest
@testable import esc_chatmail

/// What only source shows of the typed text's Dynamic Type and the forwarded card's contrast
/// (architecture review 2026-11, gap-accessibility-architecture#3): the three fields a person
/// types into at a fixed size scale with the text size, keeping their size at the default; the
/// To row grows instead of clipping; the forwarded card picks its palette by the contrast
/// setting.
///
/// HONEST SCOPE: this reads source text. Nothing was drawn at a larger text size, and the
/// cards' sizes stay fixed points on purpose (`EmailPreviewCardMetrics`), which this leaves
/// alone.
final class DynamicTypeAndContrastSourceTests: XCTestCase {
    /// Revert-check: `.font(.system(size: 18))` back on the To label or the recipient field in
    /// `RecipientInputSection` fails the count; `.frame(height: 52)` back on the iMessage row
    /// fails the last assertion.
    func testToRow_labelAndFieldScaleAndTheRowHasAMinimumHeight() throws {
        let source = try repositorySource("esc-chatmail/Views/Compose/RecipientInputSection.swift")

        XCTAssertEqual(source.components(separatedBy: ".scaledSystemFont(size: 18)").count - 1, 2)
        XCTAssertFalse(source.contains(".font(.system(size: 18))"))
        XCTAssertTrue(source.contains(".frame(minHeight: 52)"))
        XCTAssertFalse(source.contains(".frame(height: 52)"))
    }

    /// Revert-check: `.system(size: 18)` back as the iMessage body's `textFont` in
    /// `ComposeInputBar` fails this.
    func testNewMessageBody_scalesFromEighteenPoints() throws {
        let source = try repositorySource("esc-chatmail/Views/Compose/ComposeInputBar.swift")

        XCTAssertTrue(source.contains("@ScaledMetric(relativeTo: .body) private var iMessageBodyTextSize: CGFloat = 18"))
        XCTAssertTrue(source.contains("textFont: style == .iMessage ? .system(size: iMessageBodyTextSize) : .body,"))
    }

    /// Revert-check: `.font(.system(size: 17, weight: .regular))` back on the search field in
    /// `ConversationListView` fails this.
    func testSearchField_usesTheBodyStyle() throws {
        let source = try repositorySource("esc-chatmail/Views/Main/ConversationListView.swift")

        XCTAssertTrue(source.contains(
            "            TextField(\"Search\", text: $viewModel.searchText, prompt: Text(\"Search\").foregroundColor(.secondary))\n"
                + "                .textFieldStyle(.plain)\n"
        ))
        XCTAssertFalse(source.contains(".font(.system(size: 17, weight: .regular))"))
    }

    /// Revert-check: the card's colors as literals again (`isFromMe ? Color.white.opacity(0.82)`)
    /// in `ForwardedMessageCard` fails this.
    func testForwardedCard_picksItsPaletteByTheContrastSetting() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/ForwardedMessageCard.swift")

        XCTAssertTrue(source.contains("@Environment(\\.colorSchemeContrast) private var colorSchemeContrast"))
        XCTAssertTrue(source.contains("ForwardedMessageCardPalette.palette(isFromMe: isFromMe, contrast: colorSchemeContrast)"))
        XCTAssertFalse(source.contains("Color.white.opacity(0.82)"))
    }
}
