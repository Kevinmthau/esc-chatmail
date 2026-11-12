import SwiftUI
import XCTest
@testable import esc_chatmail

/// The avatar's size follows the diameter it is given. Every size in the avatar views was a
/// literal for the iOS list's 44 points until the Mac sidebar needed a smaller avatar
/// (`ConversationRowMetrics.mac`); these run in the iOS suite and in `Mac.xctestplan`.
///
/// HONEST SCOPE: the size tests measure the avatar's outer size, mounted on its own, with no
/// photo (a photo loads asynchronously and is drawn at the same diameter). They cannot see
/// inside it: that a group's small avatars and their offsets scale too is pinned only through
/// `InitialsAvatarStyle.scaled(to:)` below, and was otherwise checked by drawing the Mac row off
/// screen (`docs/mac-imessage-ui-plan.md`, "PR 2 as built").
///
/// The color tests draw a group's avatar with `ImageRenderer` and read two of its pixels. They
/// see the disc and the ring of a small avatar that has no photo yet. A loaded photo's ring is
/// the same `GroupAvatarColors.ring`, handed to `CachedAsyncImage`, and is not drawn here.
@MainActor
final class AvatarStackViewLayoutTests: XCTestCase {
    private static let macDiameter = ConversationRowMetrics.mac.avatarDiameter

    /// Colors no system color is, so a pixel in one of them was drawn from the value given.
    private static let probeColors = GroupAvatarColors(
        disc: Color(red: 1, green: 0, blue: 0),
        ring: Color(red: 0, green: 1, blue: 0)
    )
    /// Inside the disc of a 44-point group avatar of two, above both small avatars.
    private static let pointOnTheDisc = CGPoint(x: 22.25, y: 2.75)
    /// On the left small avatar's ring, at its leftmost point: the avatar is 20 points across,
    /// centered 8 points left of the disc's center, and its ring is 1.5 points wide.
    private static let pointOnTheLeftRing = CGPoint(x: 4.25, y: 22.25)

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

    // MARK: - A group's colors

    /// Revert-check: filling the disc with `Color.systemGray6` in `GroupAvatarView.body` makes
    /// the first assertion fail, and dropping `.bordered(in: colors.ring)` from the small
    /// initials avatar there makes the second fail.
    func testGroupAvatar_drawsItsDiscAndItsInitialsRingsInTheColorsGiven() throws {
        let avatar = AvatarStackView(
            avatarPhotos: [],
            participants: ["Ann Lee", "Bo Chen"],
            groupColors: Self.probeColors
        )

        let disc = try pixel(of: avatar, at: Self.pointOnTheDisc)
        let ring = try pixel(of: avatar, at: Self.pointOnTheLeftRing)

        XCTAssertEqual(disc, Pixel(red: 255, green: 0, blue: 0), "the disc")
        XCTAssertEqual(ring, Pixel(red: 0, green: 255, blue: 0), "the ring of a small initials avatar")
    }

    /// A participant with no usable name is drawn as a person icon, which has a ring of its
    /// own.
    ///
    /// Revert-check: stroking the person icon's circle with `Color.systemBackground` in
    /// `GroupAvatarView.body` makes this fail.
    func testGroupAvatar_drawsThePersonIconsRingInTheColorGiven() throws {
        let avatar = AvatarStackView(
            avatarPhotos: [],
            participants: ["Unknown", "Unknown"],
            groupColors: Self.probeColors
        )

        XCTAssertEqual(
            try pixel(of: avatar, at: Self.pointOnTheLeftRing),
            Pixel(red: 0, green: 255, blue: 0)
        )
    }

    /// A photo that has not loaded is drawn as the participant's initials, inside the same
    /// ring.
    ///
    /// Revert-check: dropping `.bordered(in: ringColor)` from the initials in
    /// `SmallCachedAvatarView.body` makes this fail.
    func testGroupAvatar_drawsAPendingPhotosRingInTheColorGiven() throws {
        let pendingPhoto = ProfilePhoto(source: .cached, imageData: nil, url: nil)
        let avatar = AvatarStackView(
            avatarPhotos: [pendingPhoto, pendingPhoto],
            participants: ["Ann Lee", "Bo Chen"],
            groupColors: Self.probeColors
        )

        XCTAssertEqual(
            try pixel(of: avatar, at: Self.pointOnTheLeftRing),
            Pixel(red: 0, green: 255, blue: 0)
        )
    }

    /// The iOS list passes no colors, and the avatar draws what it drew before they were a
    /// value.
    ///
    /// Revert-check: changing the default of `groupColors` in either `AvatarStackView.init`
    /// away from `.standard` makes this fail.
    func testGroupAvatar_givenNoColors_takesTheStandardOnes() {
        XCTAssertEqual(
            AvatarStackView(avatarPhotos: [], participants: ["Ann Lee", "Bo Chen"]).groupColors,
            .standard
        )
        XCTAssertEqual(
            AvatarStackView(alignedAvatarPhotos: [nil, nil], participants: ["Ann Lee", "Bo Chen"]).groupColors,
            .standard
        )
    }

    /// Revert-check: returning `self` from `InitialsAvatarStyle.bordered(in:)` makes the first
    /// assertion fail, and scaling anything there makes one of the others fail.
    func testInitialsStyle_borderedInAnotherColor_changesOnlyTheBordersColor() {
        let compact = InitialsAvatarStyle.compact
        let bordered = compact.bordered(in: Self.probeColors.ring)

        XCTAssertEqual(bordered.borderColor, Self.probeColors.ring)
        XCTAssertEqual(bordered.size, compact.size)
        XCTAssertEqual(bordered.fontSize, compact.fontSize)
        XCTAssertEqual(bordered.borderWidth, compact.borderWidth)
        XCTAssertEqual(bordered.singleNamePrefixLength, compact.singleNamePrefixLength)
    }

    private func fittingSize(_ view: some View) throws -> CGSize {
        try mountInTestWindow(view).sizeThatFits(in: CGSize(width: 200, height: 200))
    }

    private struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private struct PointOutsideTheDrawing: Error {}

    /// The pixel of `view`, drawn at two pixels a point, that holds `point`, in points from
    /// the drawing's top left corner.
    private func pixel(of view: some View, at point: CGPoint) throws -> Pixel {
        let scale: CGFloat = 2
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer drew nothing")

        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)

        // The first row of a bitmap context's bytes is the picture's top row.
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x < image.width, y < image.height else {
            XCTFail("\(point) is outside the \(image.width) by \(image.height) pixel drawing")
            throw PointOutsideTheDrawing()
        }
        let offset = y * context.bytesPerRow + x * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
    }
}
