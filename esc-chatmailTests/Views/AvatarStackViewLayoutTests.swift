import SwiftUI
import XCTest
@testable import esc_chatmail

/// The avatar's size follows the diameter it is given. Every size in the avatar views was a
/// literal for the iOS list's 44 points until the Mac sidebar needed a smaller avatar
/// (`ConversationRowMetrics.mac`); these run in the iOS suite and in `Mac.xctestplan`.
///
/// HONEST SCOPE: these measure the avatar's outer size, mounted on its own, with no photo (a
/// photo loads asynchronously and is drawn at the same diameter). They cannot see inside it: that
/// a group's small avatars and their offsets scale too is pinned only through
/// `InitialsAvatarStyle.scaled(to:)` below, and was otherwise checked by drawing the Mac row off
/// screen (`docs/mac-imessage-ui-plan.md`, "PR 2 as built").
@MainActor
final class AvatarStackViewLayoutTests: XCTestCase {
    private static let macDiameter = ConversationRowMetrics.mac.avatarDiameter

    /// The iOS list passes no diameter it did not pass before.
    ///
    /// Revert-check: changing `AvatarStackView.designDiameter` makes this fail.
    func testSingleAvatar_atTheDefaultDiameter_isTheDesignSize() throws {
        let size = try fittingSize(
            AvatarStackView(avatarPhotos: [], participants: ["Ann Lee"])
        )

        XCTAssertEqual(size.width, 44, accuracy: 0.01)
        XCTAssertEqual(size.height, 44, accuracy: 0.01)
    }

    /// Revert-check: passing `.standard` instead of `.standard.scaled(to: diameter)` to the
    /// initials in `SingleAvatarView.fallbackAvatarView` makes this fail (44 points).
    func testSingleAvatar_initialsAtTheMacDiameter_areThatSize() throws {
        let size = try fittingSize(
            AvatarStackView(avatarPhotos: [], participants: ["Ann Lee"], diameter: Self.macDiameter)
        )

        XCTAssertEqual(size.width, Self.macDiameter, accuracy: 0.01)
        XCTAssertEqual(size.height, Self.macDiameter, accuracy: 0.01)
    }

    /// No participant and no usable title: the generic person icon.
    ///
    /// Revert-check: giving the icon `.frame(width: 44, height: 44)` in
    /// `SingleAvatarView.fallbackAvatarView` makes this fail.
    func testSingleAvatar_genericIconAtTheMacDiameter_isThatSize() throws {
        let size = try fittingSize(
            AvatarStackView(avatarPhotos: [], participants: [], diameter: Self.macDiameter)
        )

        XCTAssertEqual(size.width, Self.macDiameter, accuracy: 0.01)
        XCTAssertEqual(size.height, Self.macDiameter, accuracy: 0.01)
    }

    /// Revert-check: setting `self.mainSize = AvatarStackView.designDiameter` in
    /// `GroupAvatarView.init` makes this fail (44 points).
    func testGroupAvatar_atTheMacDiameter_isThatSize() throws {
        let size = try fittingSize(
            AvatarStackView(
                avatarPhotos: [],
                participants: ["Ann Lee", "Bo Chen", "Cy Diaz"],
                diameter: Self.macDiameter
            )
        )

        XCTAssertEqual(size.width, Self.macDiameter, accuracy: 0.01)
        XCTAssertEqual(size.height, Self.macDiameter, accuracy: 0.01)
    }

    /// At its own size a scaled style is the style: the factor is exactly 1, so the iOS list's
    /// initials keep their 15-point font.
    ///
    /// Revert-check: dividing by a fixed diameter instead of this style's own in
    /// `InitialsAvatarStyle.scaled(to:)` (`size / 40`) makes this fail.
    func testInitialsStyle_scaledToItsOwnSize_isUnchanged() {
        let standard = InitialsAvatarStyle.standard
        let scaled = standard.scaled(to: standard.size)

        XCTAssertEqual(scaled.size, standard.size)
        XCTAssertEqual(scaled.fontSize, standard.fontSize)
        XCTAssertEqual(scaled.borderWidth, standard.borderWidth)
        XCTAssertEqual(scaled.singleNamePrefixLength, standard.singleNamePrefixLength)
    }

    /// Revert-check: returning `fontSize` unscaled from `InitialsAvatarStyle.scaled(to:)` makes
    /// this fail: a 20-point initials avatar would keep the 44-point one's 15-point letters.
    func testInitialsStyle_scaledDown_scalesItsFontAndKeepsItsBorder() {
        let half = InitialsAvatarStyle.standard.scaled(to: 22)

        XCTAssertEqual(half.size, 22)
        XCTAssertEqual(half.fontSize, 7.5, accuracy: 0.001)
        XCTAssertEqual(half.borderWidth, InitialsAvatarStyle.standard.borderWidth)
    }

    private func fittingSize(_ view: some View) throws -> CGSize {
        try mountInTestWindow(view).sizeThatFits(in: CGSize(width: 200, height: 200))
    }
}
