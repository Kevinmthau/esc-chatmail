import XCTest
@testable import esc_chatmail

/// Pins, from the source text, that `ChatView` closes itself only through `exitChat()`.
///
/// In the Mac's chat column `dismiss()` does not pop a screen: it closes the window, and the Mac
/// app has one window, so that quits the app. `exitChat()` is the one place that chooses between
/// the presenter's `onExit` and `dismiss`.
///
/// HONEST SCOPE: this reads the file's text. It cannot tell that `MacMailboxView` passes an
/// `onExit`, or what `dismiss` does at run time; there is no UI test target, and the Mac app is
/// not launched to check UI.
final class ChatViewExitTests: XCTestCase {
    /// Revert-check: changing either `{ exitChat() }` in `ChatView.archiveConversationAndDismiss`
    /// or `reportSpamAndDismiss` back to `{ dismiss() }`, or the drained exit's `exitChat()`
    /// back to `dismiss()`, makes this fail.
    func testChatView_callsDismissOnlyInsideExitChat() throws {
        let source = try chatViewSource()
        let calls = source.components(separatedBy: "\n").filter { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && code.contains("dismiss()")
        }
        XCTAssertEqual(calls.count, 1, "dismiss() call sites: \(calls)")

        let exitChat = try XCTUnwrap(source.range(of: "private func exitChat() {"))
        let body = source[exitChat.upperBound...]
        let end = try XCTUnwrap(body.range(of: "\n    }\n"))
        XCTAssertTrue(
            body[..<end.lowerBound].contains("dismiss()"),
            "The one dismiss() call is not inside exitChat()"
        )
    }

    /// Revert-check: removing the `if let onExit { onExit() }` branch from `ChatView.exitChat`
    /// makes this fail.
    func testExitChat_prefersThePresentersExitHandler() throws {
        let source = try chatViewSource()
        let exitChat = try XCTUnwrap(source.range(of: "private func exitChat() {"))
        let body = source[exitChat.upperBound...]
        let end = try XCTUnwrap(body.range(of: "\n    }\n"))
        let text = String(body[..<end.lowerBound])
        let handler = try XCTUnwrap(text.range(of: "onExit()"))
        let fallback = try XCTUnwrap(text.range(of: "dismiss()"))
        XCTAssertLessThan(handler.lowerBound, fallback.lowerBound)
        XCTAssertTrue(text.contains("if let onExit"))
    }

    private func chatViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Chat
            .deletingLastPathComponent() // esc-chatmailTests
            .deletingLastPathComponent() // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent("esc-chatmail/Views/Chat/ChatView.swift"),
            encoding: .utf8
        )
    }
}
