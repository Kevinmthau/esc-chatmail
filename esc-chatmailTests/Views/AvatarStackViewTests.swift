import XCTest
@testable import esc_chatmail

final class AvatarStackViewTests: XCTestCase {

    func testResolvedLayout_withGroupConversationAndNoParticipants_usesGroupAvatar() {
        let result = AvatarStackView.resolvedLayout(
            participantCount: 0,
            showsGroupAvatar: true
        )

        XCTAssertEqual(result, .group)
    }

    func testResolvedLayout_withoutGroupConversationAndNoParticipants_usesSingleAvatar() {
        let result = AvatarStackView.resolvedLayout(
            participantCount: 0,
            showsGroupAvatar: false
        )

        XCTAssertEqual(result, .single)
    }

    func testResolvedEmptyContent_withUsableFallback_usesInitials() {
        // A group circle with no resolved participants must monogram the
        // fallback title instead of rendering a blank gray circle.
        let result = GroupAvatarView.resolvedEmptyContent(
            fallbackDisplayText: "Ally, Victoria, Daisy"
        )

        XCTAssertEqual(result, .initials("Ally, Victoria, Daisy"))
    }

    func testResolvedEmptyContent_stripsOverflowSuffixBeforeMonogramming() {
        let result = GroupAvatarView.resolvedEmptyContent(
            fallbackDisplayText: "Daisy +4"
        )

        XCTAssertEqual(result, .initials("Daisy"))
    }

    func testResolvedEmptyContent_withEmailFallback_usesInitials() {
        let result = GroupAvatarView.resolvedEmptyContent(
            fallbackDisplayText: "ally@cv-partners.com"
        )

        XCTAssertEqual(result, .initials("ally@cv-partners.com"))
    }

    func testResolvedEmptyContent_withPlaceholderFallback_keepsPlainCircle() {
        let placeholderResult = GroupAvatarView.resolvedEmptyContent(
            fallbackDisplayText: "3 Unknown Contacts"
        )
        let nilResult = GroupAvatarView.resolvedEmptyContent(fallbackDisplayText: nil)

        XCTAssertEqual(placeholderResult, .placeholderCircle)
        XCTAssertEqual(nilResult, .placeholderCircle)
    }

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

    func testInitialsSource_ignoresCountedUnknownContactsPlaceholder() {
        let result = SingleAvatarView.initialsSource(
            participant: nil,
            fallbackDisplayText: "2 Unknown Contacts"
        )

        XCTAssertNil(result)
    }
}
