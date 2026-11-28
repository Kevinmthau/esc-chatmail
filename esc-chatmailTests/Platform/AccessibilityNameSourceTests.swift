import XCTest
@testable import esc_chatmail

/// The accessible names and the row wiring only source shows (architecture review 2026-11,
/// gap-accessibility-architecture#1 and #5). Each icon-only control carries a name of its own,
/// in the shared component where there is one, so a new use site inherits it; the conversation
/// row is one element with its state as its value, and the iOS row is a button.
///
/// HONEST SCOPE: this reads source text. A test host is told nothing of SwiftUI's
/// accessibility tree, so what VoiceOver and Voice Control make of these modifiers was not
/// measured, and VoiceOver has not been heard on either platform. The policy behind the row's
/// value and traits is `ConversationRowAccessibilityPolicyTests`'.
final class AccessibilityNameSourceTests: XCTestCase {
    /// Revert-check: deleting `.accessibilityLabel("Send")` from `SendButton` makes this fail.
    func testSendButton_isNamedSend() throws {
        let source = try repositorySource("esc-chatmail/Views/Components/SendButton.swift")

        XCTAssertTrue(source.contains("        .accessibilityLabel(\"Send\")\n"))
    }

    /// Named in the shared thumbnail, once: the Forward strip's outer label came off with it.
    ///
    /// Revert-check: deleting the label from `DraftAttachmentThumbnail` fails the first
    /// assertion; putting the outer one back in `ComposeView` fails the second.
    func testDraftAttachmentRemove_isNamedForItsFileInTheSharedComponent() throws {
        let thumbnail = try repositorySource("esc-chatmail/Views/Components/DraftAttachmentThumbnail.swift")
        let compose = try repositorySource("esc-chatmail/Views/Compose/ComposeView.swift")

        XCTAssertTrue(thumbnail.contains(".accessibilityLabel(\"Remove \\(attachment.filenameValue)\")"))
        XCTAssertFalse(compose.contains(".accessibilityLabel(\"Remove"))
    }

    /// Revert-check: deleting the label from `RecipientChip` makes this fail.
    func testRecipientChipRemove_isNamedForItsRecipient() throws {
        let source = try repositorySource("esc-chatmail/Views/Compose/RecipientChip.swift")

        XCTAssertTrue(source.contains(".accessibilityLabel(\"Remove \\(recipient.display)\")"))
    }

    /// Revert-check: deleting `.accessibilityLabel("More")` after the ellipsis menu in
    /// `ChatView` makes this fail.
    func testChatMenu_isNamedMore() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/ChatView.swift")

        XCTAssertTrue(source.contains(
            "                    Image(systemName: \"ellipsis.circle\")\n"
                + "                }\n"
                + "                .accessibilityLabel(\"More\")\n"
        ))
    }

    /// Both platforms' quote X say one constant, and no other file spells it.
    ///
    /// Revert-check: deleting the label from `ChatReplyBarHeaderRow` fails the first
    /// assertion; spelling the words out again in `MacReplyIndicator` fails the last.
    func testDropQuoteX_isNamedFromOneConstantOnBothPlatforms() throws {
        let iPhone = try repositorySource("esc-chatmail/Views/Compose/ChatReplyBarHeaderRow.swift")
        let mac = try repositorySource("esc-chatmail/Platform/MacReplyIndicator.swift")

        XCTAssertTrue(iPhone.contains(".accessibilityLabel(ReplyIndicatorPolicy.dropQuoteLabel)"))
        XCTAssertTrue(mac.contains(".help(ReplyIndicatorPolicy.dropQuoteLabel)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(ReplyIndicatorPolicy.dropQuoteLabel)"))
        XCTAssertFalse(iPhone.contains("Don’t quote this message"))
        XCTAssertFalse(mac.contains("Don’t quote this message"))
    }

    /// The row is one element whose value is the policy's, and the parts without words are
    /// hidden.
    ///
    /// Revert-check: deleting `.accessibilityElement(children: .combine)` from
    /// `ConversationRowView` fails the first assertion; deleting its `.accessibilityValue`
    /// the second; deleting a decoration's `.accessibilityHidden(true)` the count.
    func testConversationRow_isOneElementWithItsStateAsItsValue() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/ConversationRowView.swift")

        XCTAssertTrue(source.contains("            .accessibilityElement(children: .combine)\n"))
        XCTAssertTrue(source.contains(".accessibilityValue(ConversationRowAccessibilityPolicy.value("))
        XCTAssertEqual(
            source.components(separatedBy: ".accessibilityHidden(true)").count - 1,
            4,
            "The unread dot, the avatar, the pin and the chevron"
        )
    }

    /// The iOS list's row is a button that does what a tap does, with the policy's traits, and
    /// its checkbox is hidden.
    ///
    /// Revert-check: deleting the `.accessibilityAddTraits` call in `ConversationListView`
    /// fails the first assertion, the `.accessibilityAction` the second, and the checkbox's
    /// `.accessibilityHidden(true)` the third.
    func testConversationListRow_isAButtonWhoseActionIsTheTap() throws {
        let source = try repositorySource("esc-chatmail/Views/Main/ConversationListView.swift")

        XCTAssertTrue(source.contains(".accessibilityAddTraits(ConversationRowAccessibilityPolicy.listRowTraits("))
        XCTAssertTrue(source.contains(".accessibilityAction { activateRow(item.id) }"))
        XCTAssertTrue(source.contains(
            "        .padding(.trailing, 8)\n"
                + "        // The row it sits in is a button that toggles the same selection and says whether it\n"
                + "        // is selected (`ConversationRowAccessibilityPolicy.listRowTraits`).\n"
                + "        .accessibilityHidden(true)\n"
        ))
        XCTAssertTrue(source.contains(".onTapGesture { activateRow(item.id) }"))
    }
}
