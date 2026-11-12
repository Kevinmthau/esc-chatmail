import XCTest
@testable import esc_chatmail

/// What each `ChatComposerStyle` draws and does (`ChatComposerPolicy`,
/// `docs/mac-imessage-ui-plan.md`, PR 5). Pure, so it runs in the iOS suite and in
/// `Mac.xctestplan`.
///
/// HONEST SCOPE: the decisions only. Which style each presenter names, and that the views ask
/// these functions, is `ChatComposerStyleSourceTests`'; the Mac's composer has not been seen
/// in the app.
final class ChatComposerPolicyTests: XCTestCase {
    // MARK: - The iPhone's bar is what it was

    /// Revert-check: returning `.fade` for `.bar` in `ChatComposerPolicy.backdrop` makes this
    /// fail: the iPhone's composer would lose its divider and its opaque bar.
    func testBar_keepsItsDividerAndOpaqueBar_andHasNoFloatingMetrics() {
        XCTAssertEqual(ChatComposerPolicy.backdrop(for: .bar), .dividerOverOpaqueBar)
        XCTAssertNil(ChatComposerPolicy.floatingMetrics(for: .bar))
    }

    /// Focusing the field on iOS raises the keyboard over the chat the user opened to read.
    ///
    /// Revert-check: returning `trigger != .keyPress` for `.bar` in
    /// `focusesFieldWhenChatAppears` makes this fail.
    func testBar_neverFocusesItsFieldWhenTheChatAppears() {
        for trigger in [ChatComposerPolicy.AppearanceTrigger.keyPress, .other] {
            XCTAssertFalse(
                ChatComposerPolicy.focusesFieldWhenChatAppears(style: .bar, trigger: trigger),
                "\(trigger)"
            )
        }
    }

    // MARK: - The Mac's floating composer

    /// Revert-check: returning `.dividerOverOpaqueBar` for `.floating` makes the first
    /// assertion fail; returning nil for `.floating` in `floatingMetrics` makes the second.
    func testFloating_hasNoBar_andDrawsAtItsOwnMetrics() {
        XCTAssertEqual(ChatComposerPolicy.backdrop(for: .floating(.mac)), .fade)
        XCTAssertEqual(ChatComposerPolicy.floatingMetrics(for: .floating(.mac)), .mac)
    }

    /// Selecting a conversation puts the caret in its field, as in Messages.
    ///
    /// Revert-check: returning false for `.floating` makes this fail.
    func testFloating_chatSelectedWithoutAKey_focusesItsField() {
        XCTAssertTrue(
            ChatComposerPolicy.focusesFieldWhenChatAppears(style: .floating(.mac), trigger: .other)
        )
    }

    /// An arrow key in the sidebar, or Delete archiving the row before: the list keeps the
    /// focus, so the next arrow moves on and the next Delete archives the next conversation.
    ///
    /// Revert-check: returning true for `.floating` whatever the trigger makes this fail.
    func testFloating_chatSelectedByAKey_leavesTheFocusWithTheSidebar() {
        XCTAssertFalse(
            ChatComposerPolicy.focusesFieldWhenChatAppears(style: .floating(.mac), trigger: .keyPress)
        )
    }

    /// Revert-check: returning `.other` for a key event in `ChatAppearanceTrigger.trigger`
    /// makes this fail.
    func testAppearanceTrigger_aKeyEventIsAKeyPress_andAnythingElseIsNot() {
        XCTAssertEqual(ChatAppearanceTrigger.trigger(isKeyEvent: true), .keyPress)
        XCTAssertEqual(ChatAppearanceTrigger.trigger(isKeyEvent: false), .other)
    }

    // MARK: - The send arrow

    /// Revert-check: returning true unconditionally from `showsSendArrow` makes the last two
    /// assertions fail; ignoring `hasAttachments` makes the second fail.
    func testSendArrow_isShownOnlyWhileThereIsSomethingToSend() {
        XCTAssertTrue(ChatComposerPolicy.showsSendArrow(replyText: "Hi", hasAttachments: false))
        XCTAssertTrue(ChatComposerPolicy.showsSendArrow(replyText: "", hasAttachments: true))
        XCTAssertFalse(ChatComposerPolicy.showsSendArrow(replyText: "", hasAttachments: false))
        XCTAssertFalse(ChatComposerPolicy.showsSendArrow(replyText: " \n ", hasAttachments: false))
    }

    // MARK: - Escape

    /// Revert-check: returning false from `escapeDropsQuote` makes this fail.
    func testEscape_dropsTheQuoteOfADismissibleReplyTarget() {
        XCTAssertTrue(
            ChatComposerPolicy.escapeDropsQuote(
                header: .replyingTo(label: "Replying to: Lunch?"),
                allowsDraftMutation: true
            )
        )
    }

    /// The X is disabled while a send owns the draft; Escape waits with it.
    ///
    /// Revert-check: deleting the `guard allowsDraftMutation` line makes this fail.
    func testEscape_whileASendOwnsTheDraft_dropsNothing() {
        XCTAssertFalse(
            ChatComposerPolicy.escapeDropsQuote(
                header: .replyingTo(label: "Replying to: Lunch?"),
                allowsDraftMutation: false
            )
        )
    }

    /// A recovered envelope has no dismiss button, an unavailable target is cleared by a
    /// button that says so, and with no row there is nothing to drop.
    ///
    /// Revert-check: returning `allowsDraftMutation` whatever the header makes this fail.
    func testEscape_dropsNothingForTheRowsThatHaveNoX() {
        for header in [
            ReplyIndicatorPolicy.Header.none,
            .recoveredEnvelope(label: "Replying to: ada@example.com"),
            .unavailableTarget
        ] {
            XCTAssertFalse(
                ChatComposerPolicy.escapeDropsQuote(header: header, allowsDraftMutation: true),
                "\(header)"
            )
        }
    }

    // MARK: - Metrics

    /// The composer's height must not change as the send arrow comes and goes with the draft,
    /// and its glass must keep clear of the chat column's edges.
    ///
    /// Revert-check: setting `inFieldButtonSide` to 34 in `ChatComposerMetrics.mac` makes the
    /// first assertion fail; setting `horizontalPadding` to 16 makes the second fail; setting
    /// `fieldCornerRadius` to 10 makes the third fail.
    func testMacMetrics_holdTheRelationsTheLayoutRestsOn() {
        let metrics = ChatComposerMetrics.mac

        XCTAssertLessThanOrEqual(metrics.inFieldButtonSide, metrics.controlDiameter)
        XCTAssertGreaterThan(metrics.horizontalPadding, 20)
        XCTAssertEqual(metrics.fieldCornerRadius, metrics.controlDiameter / 2)
        XCTAssertGreaterThanOrEqual(metrics.maximumLineCount, 1)
    }
}
