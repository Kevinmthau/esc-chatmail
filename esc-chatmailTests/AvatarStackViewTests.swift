import XCTest
@testable import esc_chatmail

final class AvatarStackViewTests: XCTestCase {

    func testResolvedContent_withPhoto_prefersPhoto() {
        let photo = ProfilePhoto(
            source: .contacts,
            imageData: Data([0x00]),
            url: nil
        )

        let result = SingleAvatarView.resolvedContent(
            avatarPhoto: photo,
            participant: "Flamingo Estate",
            fallbackDisplayText: "news@brand.com"
        )

        XCTAssertEqual(result, .photo)
    }

    func testResolvedContent_withoutPhotoWithParticipantName_usesInitials() {
        let result = SingleAvatarView.resolvedContent(
            avatarPhoto: nil,
            participant: "Flamingo Estate",
            fallbackDisplayText: nil
        )

        XCTAssertEqual(result, .initials("Flamingo Estate"))
    }

    func testResolvedContent_withoutPhotoWithEmailLikeFallback_usesInitials() {
        let result = SingleAvatarView.resolvedContent(
            avatarPhoto: nil,
            participant: nil,
            fallbackDisplayText: "news@brand.com"
        )

        XCTAssertEqual(result, .initials("news@brand.com"))
    }

    func testResolvedContent_withoutUsableName_usesGenericIcon() {
        let result = SingleAvatarView.resolvedContent(
            avatarPhoto: nil,
            participant: "   ",
            fallbackDisplayText: "\n\t"
        )

        XCTAssertEqual(result, .genericIcon)
    }

    func testInitialsSource_prefersDisplayNameFromMailboxString() {
        let result = SingleAvatarView.initialsSource(
            participant: nil,
            fallbackDisplayText: "Flamingo Estate <news@brand.com>"
        )

        XCTAssertEqual(result, "Flamingo Estate")
    }

    func testInitialsSource_ignoresPlaceholderDisplayNames() {
        let result = SingleAvatarView.initialsSource(
            participant: nil,
            fallbackDisplayText: "Unknown"
        )

        XCTAssertNil(result)
    }
}
