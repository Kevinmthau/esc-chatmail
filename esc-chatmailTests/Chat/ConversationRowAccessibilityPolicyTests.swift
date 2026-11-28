import SwiftUI
import XCTest
@testable import esc_chatmail

/// What a conversation row says beyond its texts, and what the iOS list's row is
/// (architecture review 2026-11, gap-accessibility-architecture#1 and #5). In the default plan
/// and in `Mac.xctestplan`, since the Mac sidebar's rows say the same value.
///
/// HONEST SCOPE: these pin the policy. That the row combines its texts and carries this value
/// and these traits is pinned from source (`AccessibilityNameSourceTests`); a test host is told
/// nothing of SwiftUI's accessibility tree, and VoiceOver has not been heard on either platform.
final class ConversationRowAccessibilityPolicyTests: XCTestCase {
    /// The unread dot and the pin have no words; the value says what they show.
    ///
    /// Revert-check: an empty string for every input in
    /// `ConversationRowAccessibilityPolicy.value(isUnread:isPinned:)` fails this.
    func testValue_unreadAndPinned_saysBoth() {
        XCTAssertEqual(ConversationRowAccessibilityPolicy.value(isUnread: true, isPinned: true), "Unread, Pinned")
        XCTAssertEqual(ConversationRowAccessibilityPolicy.value(isUnread: true, isPinned: false), "Unread")
        XCTAssertEqual(ConversationRowAccessibilityPolicy.value(isUnread: false, isPinned: true), "Pinned")
    }

    /// A read, unpinned row says only its texts.
    ///
    /// Revert-check: "Read" for a read row in
    /// `ConversationRowAccessibilityPolicy.value(isUnread:isPinned:)` fails this.
    func testValue_readAndUnpinned_isEmpty() {
        XCTAssertEqual(ConversationRowAccessibilityPolicy.value(isUnread: false, isPinned: false), "")
    }

    /// The iOS row is a button in both modes, selected only while selecting and in the
    /// selection.
    ///
    /// Revert-check: dropping the `isSelecting &&` term in
    /// `ConversationRowAccessibilityPolicy.listRowTraits` fails the last assertion; starting
    /// from an empty set in place of `.isButton` fails the first.
    func testListRowTraits_isAButtonAndSelectedOnlyWhileSelectingASelectedRow() {
        XCTAssertEqual(
            ConversationRowAccessibilityPolicy.listRowTraits(isSelecting: false, isSelected: false),
            .isButton
        )
        XCTAssertEqual(
            ConversationRowAccessibilityPolicy.listRowTraits(isSelecting: true, isSelected: false),
            .isButton
        )
        XCTAssertEqual(
            ConversationRowAccessibilityPolicy.listRowTraits(isSelecting: true, isSelected: true),
            [.isButton, .isSelected]
        )
        XCTAssertEqual(
            ConversationRowAccessibilityPolicy.listRowTraits(isSelecting: false, isSelected: true),
            .isButton,
            "A selection left over from an earlier Select is not this row's state"
        )
    }
}
