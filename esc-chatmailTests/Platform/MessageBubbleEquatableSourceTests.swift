import XCTest
@testable import esc_chatmail

/// The transcript's row wiring that only source shows (architecture review 2026-11,
/// chat-transcript-ui#4): the bubble is shown through `.equatable()`, so a pass of the
/// transcript re-runs only the rows whose inputs changed, and the bubble's body reads no HTML
/// file signature, which took the process-wide HTML lock on the main thread in every pass.
///
/// HONEST SCOPE: this reads source text. That an equal row's body is skipped is SwiftUI's
/// behaviour for an `Equatable` view, and was not measured; what makes two rows equal is
/// `MessageBubbleInputsTests`', and the reload a source change starts is
/// `MessageBubbleViewModelTests`' and `MessageBubbleSourceRevisionHostedTests`'.
final class MessageBubbleEquatableSourceTests: XCTestCase {
    /// Revert-check: deleting `.equatable()` after the `MessageBubble(` call in
    /// `ChatMessagesView` makes this fail.
    func testTranscript_showsEachBubbleThroughEquatable() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/ChatMessagesView.swift")
        let bubble = try XCTUnwrap(source.range(of: "MessageBubble("))
        let rest = source[bubble.upperBound...]
        // A line of code that is the modifier alone: the comments around the call name it too.
        let equatable = try XCTUnwrap(
            rest.range(of: #"\n[ ]+\.equatable\(\)\n"#, options: .regularExpression),
            "No .equatable() line after MessageBubble("
        )
        let nextModifier = try XCTUnwrap(rest.range(of: "\n                    .modifier("))

        XCTAssertLessThan(equatable.lowerBound, nextModifier.lowerBound, "`.equatable()` is the bubble's first modifier")
        XCTAssertEqual(source.components(separatedBy: "MessageBubble(").count, 2, "One bubble in the transcript")
    }

    /// Revert-check: putting back `htmlContentHandler.htmlSourceSignature(` in
    /// `MessageBubble.loadSignature` makes this fail.
    func testBubble_readsNoHTMLSourceSignature() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/MessageBubble.swift")

        XCTAssertFalse(source.contains("htmlSourceSignature("))
        XCTAssertFalse(source.contains("cachedHTMLSourceSignature("))
    }
}
