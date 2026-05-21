import XCTest
@testable import esc_chatmail

@MainActor
final class ConversationRowViewTests: XCTestCase {
    func testResolvedParticipantInfoUsesUncachedPhotosWhenCachedRollupCannotRetainThem() {
        let cachedBase = makeParticipantInfo(
            displayNames: ["Address Book Friend"],
            photos: [],
            formattedDisplayName: "Address Book Friend"
        )
        let uncached = makeParticipantInfo(
            displayNames: ["Stale Name"],
            photos: [
                ProfilePhoto(source: .contacts, imageData: Data([0x01]), url: nil)
            ],
            formattedDisplayName: "Stale Name"
        )

        let resolved = ConversationRowView.resolvedParticipantInfo(
            cachedFull: nil,
            cachedBase: cachedBase,
            uncached: uncached
        )

        XCTAssertEqual(resolved?.formattedDisplayName, "Address Book Friend")
        XCTAssertEqual(resolved?.displayNames, ["Address Book Friend"])
        XCTAssertEqual(resolved?.photos.count, 1)
        XCTAssertEqual(resolved?.photos.first?.source, .contacts)
        XCTAssertEqual(resolved?.photos.first?.imageData, Data([0x01]))
        XCTAssertNil(resolved?.photos.first?.url)
    }

    func testResolvedParticipantInfoPrefersCachedFullWhenAvailable() {
        let cachedFull = makeParticipantInfo(
            displayNames: ["Cached Friend"],
            photos: [
                ProfilePhoto(source: .cached, imageData: nil, url: "file:///tmp/avatar.jpg")
            ],
            formattedDisplayName: "Cached Friend"
        )
        let uncached = makeParticipantInfo(
            displayNames: ["Uncached Friend"],
            photos: [
                ProfilePhoto(source: .contacts, imageData: Data([0x02]), url: nil)
            ],
            formattedDisplayName: "Uncached Friend"
        )

        let resolved = ConversationRowView.resolvedParticipantInfo(
            cachedFull: cachedFull,
            cachedBase: nil,
            uncached: uncached
        )

        XCTAssertEqual(resolved?.formattedDisplayName, "Cached Friend")
        XCTAssertEqual(resolved?.displayNames, ["Cached Friend"])
        XCTAssertEqual(resolved?.photos.count, 1)
        XCTAssertEqual(resolved?.photos.first?.source, .cached)
        XCTAssertNil(resolved?.photos.first?.imageData)
        XCTAssertEqual(resolved?.photos.first?.url, "file:///tmp/avatar.jpg")
    }

    func testResolvedShowsGroupAvatarPrefersResolvedParticipantCount() {
        let participantInfo = makeParticipantInfo(
            displayNames: ["Friend"],
            photos: [],
            formattedDisplayName: "Friend",
            totalUniqueParticipants: 1
        )

        let showsGroupAvatar = ConversationRowView.resolvedShowsGroupAvatar(
            snapshotShowsGroupAvatar: true,
            participantInfo: participantInfo
        )

        XCTAssertFalse(showsGroupAvatar)
    }

    private func makeParticipantInfo(
        displayNames: [String],
        photos: [ProfilePhoto],
        formattedDisplayName: String,
        totalUniqueParticipants: Int = 1
    ) -> ParticipantLoader.ParticipantInfo {
        ParticipantLoader.ParticipantInfo(
            emails: ["friend@example.com"],
            displayNames: displayNames,
            photos: photos,
            formattedDisplayName: formattedDisplayName,
            totalUniqueParticipants: totalUniqueParticipants
        )
    }
}
