import SwiftUI
import XCTest
@testable import esc_chatmail

/// What a row draws beside its bubble, per style (`MessageBubbleRowPolicy`). Pure, so these
/// run in the iOS suite and in `Mac.xctestplan`.
final class MessageBubbleRowPolicyTests: XCTestCase {
    private typealias Policy = MessageBubbleRowPolicy

    // MARK: - Avatar

    /// The iPhone's row shows the avatar beside incoming bubbles in every chat, one-to-one
    /// included, as it did before the policy existed.
    ///
    /// Revert-check: applying the one-to-one rule to every style in `leadingSlot` makes this
    /// fail.
    func testLeadingSlot_standard_avatarInEveryChat() {
        for isOneToOne in [true, false] {
            XCTAssertEqual(
                Policy.leadingSlot(style: .standard, isOneToOneConversation: isOneToOne, endsRun: true),
                .avatar
            )
            XCTAssertEqual(
                Policy.leadingSlot(style: .standard, isOneToOneConversation: isOneToOne, endsRun: false),
                .avatarPlaceholder
            )
        }
    }

    /// Revert-check: deleting the `style.showAvatar` guard makes this fail.
    func testLeadingSlot_compact_none() {
        XCTAssertEqual(Policy.leadingSlot(style: .compact, isOneToOneConversation: false, endsRun: true), .none)
    }

    /// Revert-check: deleting the one-to-one rule from `leadingSlot` makes this fail.
    func testLeadingSlot_mac_noneInAOneToOneChat() {
        for endsRun in [true, false] {
            XCTAssertEqual(
                Policy.leadingSlot(style: .mac, isOneToOneConversation: true, endsRun: endsRun),
                .none
            )
        }
    }

    /// Revert-check: returning `.avatar` for every row of a group makes this fail.
    func testLeadingSlot_mac_group_avatarOnTheRunsLastRow() {
        XCTAssertEqual(Policy.leadingSlot(style: .mac, isOneToOneConversation: false, endsRun: true), .avatar)
        XCTAssertEqual(
            Policy.leadingSlot(style: .mac, isOneToOneConversation: false, endsRun: false),
            .avatarPlaceholder
        )
    }

    // MARK: - Sender name

    /// Revert-check: returning `startsRun` for every style in `showsSenderName` makes this
    /// fail: the iPhone's group rows would lose the name on all but the first of a run.
    func testShowsSenderName_standard_everyIncomingRowOfAGroup() {
        for startsRun in [true, false] {
            XCTAssertTrue(Policy.showsSenderName(
                style: .standard, isFromMe: false, isGroupConversation: true, startsRun: startsRun
            ))
        }
    }

    /// Revert-check: returning true for the Mac whatever `startsRun` is makes this fail.
    func testShowsSenderName_mac_onlyAboveTheRunsFirstRow() {
        XCTAssertTrue(Policy.showsSenderName(
            style: .mac, isFromMe: false, isGroupConversation: true, startsRun: true
        ))
        XCTAssertFalse(Policy.showsSenderName(
            style: .mac, isFromMe: false, isGroupConversation: true, startsRun: false
        ))
    }

    /// Revert-check: deleting `!isFromMe` or `isGroupConversation` from the guard makes this
    /// fail.
    func testShowsSenderName_neverOnOwnRowsOrInAOneToOneChat() {
        for style in [MessageBubbleStyle.standard, .mac] {
            XCTAssertFalse(Policy.showsSenderName(
                style: style, isFromMe: true, isGroupConversation: true, startsRun: true
            ))
            XCTAssertFalse(Policy.showsSenderName(
                style: style, isFromMe: false, isGroupConversation: false, startsRun: true
            ))
        }
    }

    // MARK: - Tail

    /// Revert-check: deleting the `bubbleTailWidth > 0` guard from `tail` makes this fail.
    func testTail_standard_none() {
        XCTAssertNil(Policy.tail(style: .standard, isFromMe: true, endsRun: true, layoutDirection: .leftToRight))
        XCTAssertNil(Policy.tail(style: .standard, isFromMe: false, endsRun: true, layoutDirection: .leftToRight))
    }

    /// Revert-check: deleting `endsRun` from the guard makes the nil assertions fail;
    /// returning `.right` for every row makes the incoming one fail.
    func testTail_mac_onTheRunsLastBubble_onTheRowsOwnSide() {
        XCTAssertEqual(
            Policy.tail(style: .mac, isFromMe: true, endsRun: true, layoutDirection: .leftToRight),
            .right
        )
        XCTAssertEqual(
            Policy.tail(style: .mac, isFromMe: false, endsRun: true, layoutDirection: .leftToRight),
            .left
        )
        XCTAssertNil(Policy.tail(style: .mac, isFromMe: true, endsRun: false, layoutDirection: .leftToRight))
        XCTAssertNil(Policy.tail(style: .mac, isFromMe: false, endsRun: false, layoutDirection: .leftToRight))
    }

    /// A shape is not mirrored in a right-to-left layout, but the row is.
    ///
    /// Revert-check: ignoring `layoutDirection` in `tail` makes this fail.
    func testTail_mac_rightToLeft_sidesSwap() {
        XCTAssertEqual(
            Policy.tail(style: .mac, isFromMe: true, endsRun: true, layoutDirection: .rightToLeft),
            .left
        )
        XCTAssertEqual(
            Policy.tail(style: .mac, isFromMe: false, endsRun: true, layoutDirection: .rightToLeft),
            .right
        )
    }
}
