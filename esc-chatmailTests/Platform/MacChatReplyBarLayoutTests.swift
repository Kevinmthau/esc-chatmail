#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The height of the Mac's floating composer (`MacChatReplyBarLayout`, `MacReplyIndicator`),
/// and the name its field has for VoiceOver and Voice Control. Mac only, so it runs in
/// `Mac.xctestplan`.
///
/// The composer's measured height is the transcript's bottom inset
/// (`ChatBottomInsetPolicy`). It changes when the draft does something the reader can see (a
/// second line, an attachment strip, a reply row), and must not change for anything else: the
/// send arrow comes and goes with every draft, and which reply row is shown changes its words,
/// not its height.
///
/// HONEST SCOPE: the views are laid out in a hosting view that is never shown, with empty
/// slots where `ChatReplyBar` puts the attachment strip and the "+" menu. That measures the
/// layout. It does not show the composer over a transcript, the "+" button's glass, or the
/// fade behind it; none of that has been seen in the app (`docs/mac-imessage-ui-plan.md`,
/// "PR 5 as built").
@MainActor
final class MacChatReplyBarLayoutTests: XCTestCase {
    private let metrics = ChatComposerMetrics.mac

    /// Revert-check: setting `inFieldButtonSide` to 34 in `ChatComposerMetrics.mac` makes this
    /// fail: the emoji button would make the field taller than the "+" button beside it.
    ///
    /// HONEST SCOPE: deleting `.frame(minHeight: metrics.controlDiameter)` from
    /// `MacChatReplyBarLayout.field` does not fail it. On macOS 27.2 one line of 13-point text
    /// and the field's padding come to the same 30 points, so the minimum is a second guard
    /// for a system font whose line is shorter.
    func testEmptyComposer_isOneControlTallPlusItsPadding() {
        let height = composerHeight(text: "", showsSendArrow: false)

        XCTAssertEqual(height, metrics.controlDiameter + metrics.verticalPadding * 2, accuracy: 0.5)
    }

    /// Revert-check: giving the send arrow `.padding(.vertical, 12)` in place of its
    /// `.padding(.bottom, inFieldButtonBottomPadding)` in `MacChatReplyBarLayout.field` makes
    /// this fail.
    func testSendArrowComingAndGoing_doesNotChangeTheComposersHeight() {
        for text in ["", "Hello", "One\nTwo"] {
            XCTAssertEqual(
                composerHeight(text: text, showsSendArrow: true),
                composerHeight(text: text, showsSendArrow: false),
                accuracy: 0.01,
                "text: \(text.debugDescription)"
            )
        }
    }

    /// Revert-check: giving the placeholder `.padding(.vertical, 4)` in
    /// `MacChatReplyBarLayout.field` makes this fail: typing the first character would make
    /// the composer shorter.
    func testFirstCharacter_doesNotChangeTheComposersHeight() {
        XCTAssertEqual(
            composerHeight(text: "H", showsSendArrow: true),
            composerHeight(text: "", showsSendArrow: false),
            accuracy: 0.5
        )
    }

    /// A second line makes the composer taller: that growth is what the transcript shifts for.
    ///
    /// Revert-check: returning one line's height from
    /// `MacReplyTextFieldCoordinator.fittingHeight` whatever the text makes this fail.
    func testSecondLine_makesTheComposerTaller() {
        XCTAssertGreaterThan(
            composerHeight(text: "One\nTwo", showsSendArrow: true),
            composerHeight(text: "One", showsSendArrow: true) + 10
        )
    }

    /// Every reply row is one height, whatever it says and whichever buttons it has.
    ///
    /// Revert-check: deleting `.frame(height: metrics.replyIndicatorHeight)` from
    /// `MacReplyIndicator.capsule` makes this fail.
    func testReplyIndicator_isTheMetricsHeight_forEveryRowItDraws() {
        let headers: [ReplyIndicatorPolicy.Header] = [
            .replyingTo(label: "Replying to: Lunch?"),
            .replyingTo(label: "Replying to: " + String(repeating: "a very long subject ", count: 30)),
            .recoveredEnvelope(label: "Replying to: ada@example.com"),
            .addressedTo(label: "To: ada@example.com"),
            .addressedTo(label: "To: " + String(repeating: "someone@example.com, ", count: 30)),
            .unavailableTarget
        ]

        for header in headers {
            let host = NSHostingView(rootView: indicator(header).frame(width: 400))
            XCTAssertEqual(
                host.fittingSize.height,
                metrics.replyIndicatorHeight,
                accuracy: 0.01,
                "\(header)"
            )
        }
    }

    /// Revert-check: drawing the capsule for `.none` in `MacReplyIndicator.body` makes this
    /// fail: a composer with nothing to say about its target would still be a row taller.
    func testNoReplyRow_addsNothingToTheComposer() {
        XCTAssertEqual(
            composerHeight(text: "", showsSendArrow: false, header: ReplyIndicatorPolicy.Header.none),
            composerHeight(text: "", showsSendArrow: false, header: nil),
            accuracy: 0.01
        )
    }

    /// Revert-check: replacing `spacing: metrics.rowSpacing` with `spacing: 0` in
    /// `MacChatReplyBarLayout.body` makes this fail.
    func testReplyRow_addsItsHeightAndOneRowSpacing() {
        XCTAssertEqual(
            composerHeight(text: "", showsSendArrow: false, header: .replyingTo(label: "Replying to: Lunch?")),
            composerHeight(text: "", showsSendArrow: false, header: nil)
                + metrics.replyIndicatorHeight + metrics.rowSpacing,
            accuracy: 0.5
        )
    }

    // MARK: - The field's name

    /// The field is named, for VoiceOver and Voice Control, by the word drawn over it. That
    /// word is hidden from accessibility, so the name is all either of them has: the field was
    /// named "Message" while it showed another word.
    ///
    /// Revert-check: passing `accessibilityLabel: "Message"` to `MacReplyTextField` in
    /// `MacChatReplyBarLayout.field` makes this fail.
    func testField_isNamedByTheWordItShows() throws {
        let host = MacOffscreenHost(
            window: try makeTestHostWindow(),
            size: CGSize(width: 520, height: 400),
            rootView: composer(text: "", showsSendArrow: false, placeholder: "A word of the test's")
        )
        defer { host.close() }

        let textView = try XCTUnwrap(host.waitForView(MacReplyTextView.self))

        XCTAssertEqual(textView.accessibilityLabel(), "A word of the test's")
    }

    // MARK: - Measuring

    private func indicator(_ header: ReplyIndicatorPolicy.Header) -> MacReplyIndicator {
        MacReplyIndicator(
            header: header,
            metrics: metrics,
            allowsDraftMutation: true,
            onDropQuote: {},
            onClearUnavailableTarget: {}
        )
    }

    /// The composer's height in a 520-point chat column.
    private func composerHeight(
        text: String,
        showsSendArrow: Bool,
        header: ReplyIndicatorPolicy.Header? = nil
    ) -> CGFloat {
        let host = NSHostingView(
            rootView: composer(text: text, showsSendArrow: showsSendArrow, header: header)
        )
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The composer as `ChatReplyBar` builds it, 520 points wide, with empty slots for the
    /// attachment strip and the "+" menu. It shows the app's own word unless a test gives
    /// another.
    private func composer(
        text: String,
        showsSendArrow: Bool,
        header: ReplyIndicatorPolicy.Header? = nil,
        placeholder: String = MessageFieldPolicy.placeholder
    ) -> some View {
        let metrics = self.metrics
        return MacChatReplyBarLayout(
            metrics: metrics,
            text: .constant(text),
            placeholder: placeholder,
            showsSendArrow: showsSendArrow,
            isSendEnabled: showsSendArrow,
            focusBridge: ReplyFieldFocusBridge(),
            canSend: { _ in true },
            onSend: {},
            onCancel: {},
            indicator: {
                if let header {
                    MacReplyIndicator(
                        header: header,
                        metrics: metrics,
                        allowsDraftMutation: true,
                        onDropQuote: {},
                        onClearUnavailableTarget: {}
                    )
                }
            },
            attachments: { EmptyView() },
            attachmentMenu: {
                Color.clear.frame(width: metrics.controlDiameter, height: metrics.controlDiameter)
            }
        )
        .frame(width: 520)
    }
}
#endif
