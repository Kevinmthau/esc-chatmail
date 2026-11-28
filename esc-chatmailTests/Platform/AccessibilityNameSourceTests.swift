import XCTest
@testable import esc_chatmail

/// The accessible names and the row wiring that only source shows (architecture review
/// 2026-11, gap-accessibility-architecture#1 and #5): the Mac's controls and tooltips, the
/// chat's "More" menu, and that the list's tap and its accessibility action are one function.
/// Everything a mounted iOS view can show is read from its accessibility tree instead
/// (`AccessibilityNameHostedTests`, `ConversationListAccessibilityHostedTests`).
///
/// HONEST SCOPE: this reads source text. The Mac test host has no switch that makes SwiftUI
/// build its accessibility elements, so what VoiceOver on the Mac makes of these modifiers was
/// not measured; mounting `ChatView` for its menu needs a whole chat.
final class AccessibilityNameSourceTests: XCTestCase {
    /// The shared controls' tooltips are the Mac's alone: on iOS `help(_:)` is also the hint.
    ///
    /// Revert-check: deleting `.macHelp("Send")` from `SendButton` fails the first assertion;
    /// `.help(` in place of `.macHelp(` there fails the last.
    func testSharedIconControls_haveMacTooltipsOnly() throws {
        let send = try repositorySource("esc-chatmail/Views/Components/SendButton.swift")
        let thumbnail = try repositorySource("esc-chatmail/Views/Components/DraftAttachmentThumbnail.swift")
        let chat = try repositorySource("esc-chatmail/Views/Chat/ChatView.swift")

        XCTAssertTrue(send.contains("        .macHelp(\"Send\")\n"))
        XCTAssertTrue(thumbnail.contains(".macHelp(\"Remove \\(attachment.filenameValue)\")"))
        XCTAssertTrue(chat.contains("                .macHelp(\"More\")\n"))
        XCTAssertFalse(send.contains(".help("))
    }

    /// Named in the shared thumbnail, once: the Forward strip's outer label came off with it.
    ///
    /// Revert-check: putting the outer `.accessibilityLabel("Remove …")` back in `ComposeView`
    /// fails this.
    func testDraftAttachmentRemove_isNamedOnlyInTheSharedComponent() throws {
        let compose = try repositorySource("esc-chatmail/Views/Compose/ComposeView.swift")

        XCTAssertFalse(compose.contains(".accessibilityLabel(\"Remove"))
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
    /// Revert-check: deleting the label from `MacReplyIndicator` fails the second assertion;
    /// spelling the words out again there fails the last.
    func testDropQuoteX_isNamedFromOneConstantOnBothPlatforms() throws {
        let iPhone = try repositorySource("esc-chatmail/Views/Compose/ChatReplyBarHeaderRow.swift")
        let mac = try repositorySource("esc-chatmail/Platform/MacReplyIndicator.swift")

        XCTAssertTrue(mac.contains(".help(ReplyIndicatorPolicy.dropQuoteLabel)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(ReplyIndicatorPolicy.dropQuoteLabel)"))
        XCTAssertFalse(iPhone.contains("Don’t quote this message"))
        XCTAssertFalse(mac.contains("Don’t quote this message"))
    }

    /// A tap on an iOS row and its accessibility action do the same thing, through one function
    /// (the action is read from the tree in `ConversationListAccessibilityHostedTests`; the tap
    /// is not something the tree shows).
    ///
    /// Revert-check: inlining the old tap body back in place of `activateRow(item.id)` in
    /// `ConversationListView`'s `onTapGesture` fails this.
    func testConversationListRow_tapAndActivationShareOneFunction() throws {
        let source = try repositorySource("esc-chatmail/Views/Main/ConversationListView.swift")

        XCTAssertTrue(source.contains(".onTapGesture { activateRow(item.id) }"))
        XCTAssertTrue(source.contains(".accessibilityAction { activateRow(item.id) }"))
    }
}
