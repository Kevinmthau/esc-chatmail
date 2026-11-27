import XCTest
@testable import esc_chatmail

/// Where each message field gets its word and its name, which only source shows
/// (`MessageFieldPolicy`).
///
/// A field that writes its own word is not a compile error, and no policy test would notice:
/// each of the four fields wrote out its own, three "iMessage" and one "Message", and the
/// change to "Email" reached only the three. The same goes for a field's name. VoiceOver and Voice Control know a field by its accessibility label,
/// and each field draws its word as a separate text over an editor that has none of its own.
///
/// HONEST SCOPE: this reads source text, as `ChatComposerStyleSourceTests` does, so it runs in
/// the iOS suite and in CI's iOS job (CI's Mac lane runs the two Mac suites named below). It pins that each field asks the policy
/// and names its editor, and matches the spelling of each call. `MacChatReplyBarLayoutTests`
/// and `MacReplyTextFieldTests` ask the Mac's real text view for its name. Nothing asks SwiftUI
/// what it tells VoiceOver about the other fields, because a test host is told nothing: the
/// Mac's hosting view answered `accessibilityChildren()` with no children, and the iPhone
/// simulator's answered `accessibilityElements` with none, each asked twice with an update
/// between (2026-11-15, VoiceOver off). And what VoiceOver then says has not been heard on
/// either platform.
final class MessageFieldSourceTests: XCTestCase {
    /// Revert-check: writing `placeholder: "Email"` at either call in `ChatReplyBar`, or at
    /// the one in `ComposeInputBar`, makes this fail.
    func testReplyFieldsAndNewMessageField_takeTheirWordFromThePolicy() throws {
        let replyBar = try source("esc-chatmail/Views/Compose/ChatReplyBar.swift")
        let inputBar = try source("esc-chatmail/Views/Compose/ComposeInputBar.swift")

        // The iPhone's bar, and the Mac's floating composer.
        XCTAssertTrue(replyBar.contains(
            "        PlaceholderTextField(text: $replyText, placeholder: MessageFieldPolicy.placeholder)\n"
        ))
        XCTAssertTrue(replyBar.contains(
            "            placeholder: MessageFieldPolicy.placeholder,\n"
                + "            showsSendArrow:"
        ))
        XCTAssertTrue(inputBar.contains(
            "                    text: $viewModel.body,\n"
                + "                    placeholder: MessageFieldPolicy.placeholder,\n"
        ))
    }

    /// The body of the compose sheet that has a Subject field is an editor of its own, not a
    /// `PlaceholderTextField`: the word is drawn over it, and the editor is named by it.
    ///
    /// Revert-check: writing `"Message"` for `bodyPlaceholder`'s value in `ComposeView` makes
    /// the first assertion fail; deleting `.accessibilityLabel(bodyPlaceholder)` from the
    /// `TextEditor` makes the second fail; deleting `.accessibilityHidden(true)` from the
    /// text drawn over it makes the third fail.
    func testSubjectFormBody_showsThePolicysWords_andIsNamedByThem() throws {
        let compose = try source("esc-chatmail/Views/Compose/ComposeView.swift")

        XCTAssertTrue(compose.contains(
            "    private var bodyPlaceholder: String {\n"
                + "        MessageFieldPolicy.composeBodyPlaceholder(isForward: viewModel.isForwardMode)\n"
                + "    }\n"
        ))
        XCTAssertTrue(compose.contains(
            "                    TextEditor(text: $viewModel.body)\n"
                + "                        .focused($focusedField, equals: .body)\n"
                + "                        .padding(.horizontal, 8)\n"
                + "                        .frame(minHeight: viewModel.isForwardMode ? 120 : nil)\n"
                + "                        .accessibilityLabel(bodyPlaceholder)\n"
        ))
        XCTAssertTrue(compose.contains(
            "                        Text(bodyPlaceholder)\n"
                + "                            .foregroundColor(.gray.opacity(0.5))\n"
                + "                            .padding(.horizontal, 12)\n"
                + "                            .padding(.top, 8)\n"
                + "                            .allowsHitTesting(false)\n"
                + "                            .accessibilityHidden(true)\n"
        ))
    }

    /// The field every other message field on iOS is: the drawn word is hidden from
    /// accessibility and the text field carries it. Left as it was, VoiceOver read the word as
    /// text of its own and then a text field with no name.
    ///
    /// Revert-check: deleting `.accessibilityLabel(placeholder)` from the `TextField` in
    /// `PlaceholderTextField` makes the first assertion fail; deleting
    /// `.accessibilityHidden(true)` from the text over it makes the second fail.
    func testPlaceholderTextField_namesItsFieldByTheWord_andHidesTheDrawnOne() throws {
        let field = try source("esc-chatmail/Views/Components/PlaceholderTextField.swift")

        XCTAssertTrue(field.contains(
            "            TextField(\"\", text: $text, axis: .vertical)\n"
                + "                .font(textFont)\n"
                + "                .padding(.horizontal, horizontalPadding)\n"
                + "                .padding(.vertical, verticalPadding)\n"
                + "                .lineLimit(lineLimit)\n"
                + "                .accessibilityLabel(placeholder)\n"
        ))
        XCTAssertTrue(field.contains(
            "                Text(placeholder)\n"
                + "                    .foregroundColor(Color.placeholderText)\n"
                + "                    .font(textFont)\n"
                + "                    .padding(.horizontal, horizontalPadding)\n"
                + "                    .padding(.vertical, verticalPadding)\n"
                + "                    .accessibilityHidden(true)\n"
        ))
    }

    /// The Mac's field: the layout hides the word it draws and hands it to the text view as
    /// its name, and the text view has no name of its own to fall back on.
    ///
    /// Revert-check: passing `accessibilityLabel: "Message"` to `MacReplyTextField` in
    /// `MacChatReplyBarLayout` makes the first assertion fail; deleting
    /// `.accessibilityHidden(true)` from the word the layout draws makes the second fail;
    /// `textView.setAccessibilityLabel("Message")` in `MacReplyTextField.updateNSView` makes
    /// the third and the fourth fail.
    func testMacField_isNamedByTheWordTheLayoutDrawsOverIt() throws {
        let layout = try source("esc-chatmail/Platform/MacChatReplyBarLayout.swift")
        let field = try source("esc-chatmail/Platform/MacReplyTextField.swift")

        XCTAssertTrue(layout.contains("                    accessibilityLabel: placeholder,\n"))
        XCTAssertTrue(layout.contains(
            "                    Text(placeholder)\n"
                + "                        .font(.system(size: metrics.fontSize))\n"
                + "                        .foregroundStyle(Color.placeholderText)\n"
                + "                        .lineLimit(1)\n"
                + "                        .allowsHitTesting(false)\n"
                + "                        .accessibilityHidden(true)\n"
        ))
        XCTAssertTrue(field.contains(
            "            if textView.accessibilityLabel() != accessibilityLabel {\n"
                + "                textView.setAccessibilityLabel(accessibilityLabel)\n"
                + "            }\n"
        ))
        XCTAssertFalse(field.contains("setAccessibilityLabel(\""))
    }

    // MARK: - Reading source

    private func source(_ relativePath: String) throws -> String {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
