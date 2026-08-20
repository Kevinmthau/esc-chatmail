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

        let resolved = ConversationRowPolicy.resolvedParticipantInfo(
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

        let resolved = ConversationRowPolicy.resolvedParticipantInfo(
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

        let showsGroupAvatar = ConversationRowPolicy.resolvedShowsGroupAvatar(
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

        let showsGroupAvatar = ConversationRowPolicy.resolvedShowsGroupAvatar(
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

        let displayName = ConversationRowPolicy.resolvedDisplayName(
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
            ConversationRowPolicy.shouldLoadParticipantInfo(conversationType: .list)
        )
        XCTAssertTrue(
            ConversationRowPolicy.resolvedAvatarDisplayNames(
                conversationType: .list,
                participantInfo: participantInfo
            ).isEmpty
        )
        XCTAssertTrue(
            ConversationRowPolicy.resolvedAvatarPhotos(
                conversationType: .list,
                participantInfo: participantInfo
            ).isEmpty
        )
        XCTAssertEqual(
            ConversationRowPolicy.resolvedDisplayName(
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

    // Revert-check: ConversationSnapshot.participantFields(from:) — merging its two
    // per-person rules (dropping the hide-my-email exclusion from participantEmails,
    // or adding it to the fingerprint) fails this test.
    // HONEST SCOPE: a full revert to the pre-F15 two-walk helpers preserved the same
    // asymmetry and would pass; this pins the asymmetry itself, not the single walk.
    func testConversationSnapshot_hideMyEmailParticipant_excludedFromEmailsButKeptInFingerprint() {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let friend = PersonBuilder()
            .withEmail("Friend@Example.com")
            .withDisplayName("Friend")
            .build(in: context)
        let relay = PersonBuilder()
            .withEmail("relay@privaterelay.appleid.com")
            .withDisplayName("Hide My Email")
            .build(in: context)
        let conversation = ConversationBuilder()
            .visible()
            .withParticipant(friend)
            .withParticipant(relay)
            .build(in: context)

        let snapshot = ConversationSnapshot(from: conversation)

        XCTAssertEqual(snapshot.participantEmails, ["friend@example.com"])
        XCTAssertEqual(
            snapshot.participantDisplayNameFingerprint,
            "friend@example.com=Friend|relay@privaterelay.appleid.com=Hide My Email"
        )
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
