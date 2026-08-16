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

    func testResolvedShowsGroupAvatarPrefersResolvedParticipantCountForNonListConversation() {
        let participantInfo = makeParticipantInfo(
            displayNames: ["Friend"],
            photos: [],
            formattedDisplayName: "Friend",
            totalUniqueParticipants: 1
        )

        let showsGroupAvatar = ConversationRowView.resolvedShowsGroupAvatar(
            snapshotShowsGroupAvatar: true,
            conversationType: .group,
            participantInfo: participantInfo
        )

        XCTAssertFalse(showsGroupAvatar)
    }

    func testResolvedShowsGroupAvatarKeepsListPresentationWithOneSeedParticipant() {
        let participantInfo = makeParticipantInfo(
            displayNames: ["First Sender"],
            photos: [],
            formattedDisplayName: "First Sender",
            totalUniqueParticipants: 1
        )

        let showsGroupAvatar = ConversationRowView.resolvedShowsGroupAvatar(
            snapshotShowsGroupAvatar: true,
            conversationType: .list,
            participantInfo: participantInfo
        )

        XCTAssertTrue(showsGroupAvatar)
    }

    func testResolvedDisplayNameKeepsStoredListIdTitleAfterParticipantLoad() {
        let participantInfo = makeParticipantInfo(
            displayNames: ["First Sender"],
            photos: [],
            formattedDisplayName: "First Sender"
        )

        let displayName = ConversationRowView.resolvedDisplayName(
            conversationType: .list,
            storedDisplayName: "Swift Evolution",
            participantInfo: participantInfo
        )

        XCTAssertEqual(displayName, "Swift Evolution")
    }

    func testListRowsSkipParticipantLoadingAndPersonalAvatarRendering() {
        let participantInfo = makeParticipantInfo(
            displayNames: ["First Sender"],
            photos: [
                ProfilePhoto(source: .contacts, imageData: Data([0x01]), url: nil)
            ],
            formattedDisplayName: "First Sender"
        )

        XCTAssertFalse(
            ConversationRowView.shouldLoadParticipantInfo(conversationType: .list)
        )
        XCTAssertTrue(
            ConversationRowView.resolvedAvatarDisplayNames(
                conversationType: .list,
                participantInfo: participantInfo
            ).isEmpty
        )
        XCTAssertTrue(
            ConversationRowView.resolvedAvatarPhotos(
                conversationType: .list,
                participantInfo: participantInfo
            ).isEmpty
        )
        XCTAssertEqual(
            ConversationRowView.resolvedDisplayName(
                conversationType: .list,
                storedDisplayName: "Swift Evolution",
                participantInfo: participantInfo
            ),
            "Swift Evolution"
        )
    }

    func testListSnapshotDoesNotCaptureCreationSeedParticipants() {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let conversation = ConversationBuilder()
            .asList()
            .withListId("swift-evolution.swift.org")
            .withDisplayName("Swift Evolution")
            .visible()
            .build(in: context)
        let person = PersonBuilder()
            .withEmail("first-sender@example.com")
            .withDisplayName("First Sender")
            .build(in: context)
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation

        let snapshot = ConversationSnapshot(from: conversation)

        XCTAssertEqual(snapshot.displayNameHint, "Swift Evolution")
        XCTAssertTrue(snapshot.participantEmails.isEmpty)
        XCTAssertTrue(snapshot.participantDisplayNameFingerprint.isEmpty)
        XCTAssertTrue(snapshot.showsGroupAvatar)
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
