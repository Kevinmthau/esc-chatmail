import XCTest
@testable import esc_chatmail

/// What the Mac's reply field does with Return, its modified forms and Escape
/// (`ReplyFieldKeyPolicy`). Pure, so it runs in the iOS suite and in `Mac.xctestplan`.
///
/// Return sends mail that can't be unsent. Each test here is one way a Return could send when
/// it should not, or fail to send when it should.
///
/// HONEST SCOPE: the policy only. That the text view asks it, with the key's real Shift and
/// repeat and the field's real marked text, is `MacReplyTextFieldTests`'; that a real input
/// method keeps its Return from the field at all has not been seen in the app.
final class ReplyFieldKeyPolicyTests: XCTestCase {
    private func context(
        isShiftDown: Bool = false,
        isKeyRepeat: Bool = false,
        hasMarkedText: Bool = false,
        canSend: Bool = true
    ) -> ReplyFieldKeyPolicy.Context {
        ReplyFieldKeyPolicy.Context(
            isShiftDown: isShiftDown,
            isKeyRepeat: isKeyRepeat,
            hasMarkedText: hasMarkedText,
            canSend: canSend
        )
    }

    /// Revert-check: returning `.insertNewline` for a plain Return in
    /// `ReplyFieldKeyPolicy.action` makes this fail.
    func testReturn_withSomethingToSend_sends() {
        XCTAssertEqual(ReplyFieldKeyPolicy.action(for: .insertNewline, context: context()), .send)
    }

    /// Nothing to send, a send that already owns the draft, an attachment still being read:
    /// Return does nothing, and adds no line to the mail that is sent a moment later.
    ///
    /// Revert-check: replacing `context.canSend ? .send : .ignore` with `.send` makes this
    /// fail; so does replacing it with `context.canSend ? .send : .insertNewline`.
    func testReturn_whenTheComposerCannotSend_doesNothing() {
        XCTAssertEqual(
            ReplyFieldKeyPolicy.action(for: .insertNewline, context: context(canSend: false)),
            .ignore
        )
    }

    /// The spike's finding: left to a SwiftUI `TextField`, Shift-Return submitted.
    ///
    /// Revert-check: deleting the `if context.isShiftDown` line makes this fail.
    func testShiftReturn_addsALineAndNeverSends() {
        XCTAssertEqual(
            ReplyFieldKeyPolicy.action(for: .insertNewline, context: context(isShiftDown: true)),
            .insertNewline
        )
        XCTAssertEqual(
            ReplyFieldKeyPolicy.action(
                for: .insertNewline,
                context: context(isShiftDown: true, canSend: false)
            ),
            .insertNewline
        )
    }

    /// The Return that confirms an input method's word confirms the word. It does not send,
    /// with or without Shift, and it adds no line.
    ///
    /// Revert-check: deleting the `if context.hasMarkedText` line from the `.insertNewline`
    /// case makes this fail.
    func testReturn_overMarkedText_commitsItAndNeverSends() {
        for isShiftDown in [false, true] {
            XCTAssertEqual(
                ReplyFieldKeyPolicy.action(
                    for: .insertNewline,
                    context: context(isShiftDown: isShiftDown, hasMarkedText: true)
                ),
                .commitMarkedText,
                "isShiftDown: \(isShiftDown)"
            )
        }
    }

    /// A reply a failed send handed back must not go out again because Return was still down.
    ///
    /// Revert-check: deleting the `if context.isKeyRepeat` line makes this fail.
    func testHeldReturn_doesNotSendAgain() {
        XCTAssertEqual(
            ReplyFieldKeyPolicy.action(for: .insertNewline, context: context(isKeyRepeat: true)),
            .ignore
        )
    }

    /// Held Shift-Return keeps adding lines: only a send must not repeat.
    ///
    /// Revert-check: moving the `isKeyRepeat` check above the `isShiftDown` check makes this
    /// fail.
    func testHeldShiftReturn_keepsAddingLines() {
        XCTAssertEqual(
            ReplyFieldKeyPolicy.action(
                for: .insertNewline,
                context: context(isShiftDown: true, isKeyRepeat: true)
            ),
            .insertNewline
        )
    }

    /// Option-Return and Control-Return add a line whatever the composer could send.
    ///
    /// Revert-check: returning `context.canSend ? .send : .ignore` for these two commands
    /// makes this fail.
    func testOptionAndControlReturn_addALineAndNeverSend() {
        for command in [
            ReplyFieldKeyPolicy.Command.insertNewlineIgnoringFieldEditor,
            .insertLineBreak
        ] {
            for canSend in [true, false] {
                XCTAssertEqual(
                    ReplyFieldKeyPolicy.action(for: command, context: context(canSend: canSend)),
                    .insertNewline,
                    "\(command), canSend: \(canSend)"
                )
            }
            XCTAssertEqual(
                ReplyFieldKeyPolicy.action(for: command, context: context(hasMarkedText: true)),
                .commitMarkedText,
                "\(command)"
            )
        }
    }

    /// Revert-check: returning `.ignore` for `.cancelOperation` makes the first assertion
    /// fail; returning `.cancel` whatever the context makes the second fail.
    func testEscape_isOfferedToTheComposer_unlessItWasTheInputMethods() {
        XCTAssertEqual(ReplyFieldKeyPolicy.action(for: .cancelOperation, context: context()), .cancel)
        XCTAssertEqual(
            ReplyFieldKeyPolicy.action(for: .cancelOperation, context: context(hasMarkedText: true)),
            .ignore
        )
    }

    /// The four commands the field decides, by the names the text system gives them, and no
    /// other: typing, deleting and moving the caret stay the text view's.
    ///
    /// Revert-check: misspelling a name in `Command.init(selectorName:)` (`"insertNewline"`
    /// without its colon) makes this fail.
    func testCommand_isReadFromTheTextSystemsSelectorNames() {
        XCTAssertEqual(ReplyFieldKeyPolicy.Command(selectorName: "insertNewline:"), .insertNewline)
        XCTAssertEqual(
            ReplyFieldKeyPolicy.Command(selectorName: "insertNewlineIgnoringFieldEditor:"),
            .insertNewlineIgnoringFieldEditor
        )
        XCTAssertEqual(ReplyFieldKeyPolicy.Command(selectorName: "insertLineBreak:"), .insertLineBreak)
        XCTAssertEqual(ReplyFieldKeyPolicy.Command(selectorName: "cancelOperation:"), .cancelOperation)
        for name in ["deleteBackward:", "insertTab:", "moveLeft:", "insertText:", "noop:"] {
            XCTAssertNil(ReplyFieldKeyPolicy.Command(selectorName: name), name)
        }
    }
}
