import SwiftUI
import XCTest
@testable import esc_chatmail

/// What a chat's header shows for each `ChatHeaderStyle` (`ChatHeaderPolicy`,
/// `ChatHeaderMetrics`). Pure functions and plain values, so these run in the iOS suite and in
/// `Mac.xctestplan`.
///
/// HONEST SCOPE: these pin the decisions, not that `ChatView` draws them. That the iOS chat
/// draws what it drew before a chat had a header style was checked once, by drawing it before
/// and after and comparing the pixels, and the Mac header was drawn off screen; neither header
/// has been seen in the Mac app (`docs/mac-imessage-ui-plan.md`, "PR 3 as built").
final class ChatHeaderPolicyTests: XCTestCase {
    // MARK: - The toolbar's principal item

    /// The iOS chat's header is its title, as before a chat had a header style.
    ///
    /// Revert-check: returning `.avatar(diameter: 40)` for `.navigationTitle` from
    /// `ChatHeaderPolicy.principalItem(for:)` makes this fail.
    func testPrincipalItem_navigationTitleStyle_isTheTitle() {
        XCTAssertEqual(ChatHeaderPolicy.principalItem(for: .navigationTitle), .title)
    }

    /// Revert-check: returning `.title` for `.avatarOverNameCapsule` from
    /// `ChatHeaderPolicy.principalItem(for:)` makes this fail: the Mac's toolbar would show the
    /// name, and the name capsule under it would show it a second time.
    func testPrincipalItem_avatarOverNameCapsuleStyle_isTheAvatarAtTheStylesDiameter() {
        XCTAssertEqual(
            ChatHeaderPolicy.principalItem(for: .avatarOverNameCapsule(.mac)),
            .avatar(diameter: 40)
        )
        XCTAssertEqual(
            ChatHeaderPolicy.principalItem(for: .avatarOverNameCapsule(Self.metrics(avatarDiameter: 28))),
            .avatar(diameter: 28)
        )
    }

    // MARK: - The glass behind the principal item

    /// The iOS title is left as the navigation bar draws it.
    ///
    /// Revert-check: returning true for `.navigationTitle` from
    /// `ChatHeaderPolicy.hidesPrincipalItemGlass(for:)` makes this fail.
    func testHidesPrincipalItemGlass_navigationTitleStyle_doesNot() {
        XCTAssertFalse(ChatHeaderPolicy.hidesPrincipalItemGlass(for: .navigationTitle))
    }

    /// The avatar is drawn bare. This goes with `ChatHeaderMetrics.mac`'s
    /// `principalItemCenterOffset`: the toolbar centers the item 0.5 points right of the chat
    /// column's center without its glass and 2.5 with it.
    ///
    /// Revert-check: returning false for `.avatarOverNameCapsule` from
    /// `ChatHeaderPolicy.hidesPrincipalItemGlass(for:)` makes this fail: the avatar would sit on
    /// the toolbar's glass, 2 points right of the name capsule under it.
    func testHidesPrincipalItemGlass_avatarOverNameCapsuleStyle_does() {
        XCTAssertTrue(ChatHeaderPolicy.hidesPrincipalItemGlass(for: .avatarOverNameCapsule(.mac)))
    }

    // MARK: - The name bar

    /// The iOS transcript gets no bar, so its top inset is what it was.
    ///
    /// Revert-check: returning `ChatHeaderMetrics.mac` for `.navigationTitle` from
    /// `ChatHeaderPolicy.nameBarMetrics(for:)` makes this fail.
    func testNameBarMetrics_navigationTitleStyle_hasNoBar() {
        XCTAssertNil(ChatHeaderPolicy.nameBarMetrics(for: .navigationTitle))
    }

    /// Revert-check: returning nil for `.avatarOverNameCapsule` from
    /// `ChatHeaderPolicy.nameBarMetrics(for:)` makes this fail: the Mac's header would be an
    /// avatar with no name.
    func testNameBarMetrics_avatarOverNameCapsuleStyle_areTheStylesMetrics() {
        XCTAssertEqual(ChatHeaderPolicy.nameBarMetrics(for: .avatarOverNameCapsule(.mac)), .mac)
    }

    // MARK: - Opening Participants

    /// A mailing list's participant rows only seed the conversation from its first message;
    /// they are not its membership (`ChatView.allowsParticipantListPresentation`).
    ///
    /// Revert-check: returning true from `ChatHeaderPolicy.opensParticipants(conversationType:)`
    /// makes this fail.
    func testOpensParticipants_mailingList_doesNot() {
        XCTAssertFalse(ChatHeaderPolicy.opensParticipants(conversationType: .list))
    }

    /// Revert-check: returning false from `ChatHeaderPolicy.opensParticipants(conversationType:)`
    /// makes this fail: nothing in the Mac header would open Participants.
    func testOpensParticipants_peopleAndGroups_do() {
        XCTAssertTrue(ChatHeaderPolicy.opensParticipants(conversationType: .oneToOne))
        XCTAssertTrue(ChatHeaderPolicy.opensParticipants(conversationType: .group))
    }

    // MARK: - Which participant info

    /// Revert-check: changing `loaded ?? cached()` to `cached() ?? loaded` in
    /// `ChatHeaderPolicy.participantInfo(loaded:cached:)` makes this fail, on the name and on
    /// the cache having been read.
    func testParticipantInfo_loadHasLanded_isTheLoadedInfoAndTheCacheIsNotRead() {
        var cacheReads = 0
        let resolved = ChatHeaderPolicy.participantInfo(
            loaded: Self.info(names: ["Loaded"]),
            cached: {
                cacheReads += 1
                return Self.info(names: ["Cached"])
            }()
        )

        XCTAssertEqual(resolved?.formattedDisplayName, "Loaded")
        XCTAssertEqual(cacheReads, 0)
    }

    /// Revert-check: changing `loaded ?? cached()` to `loaded` in
    /// `ChatHeaderPolicy.participantInfo(loaded:cached:)` makes this fail: the avatar would show
    /// initials until the load lands, for a conversation whose photo the list is already
    /// showing.
    func testParticipantInfo_loadHasNotLanded_isWhatTheRowCached() {
        let resolved = ChatHeaderPolicy.participantInfo(
            loaded: nil,
            cached: Self.info(names: ["Cached"])
        )

        XCTAssertEqual(resolved?.formattedDisplayName, "Cached")
    }

    func testParticipantInfo_nothingLoadedOrCached_isNil() {
        XCTAssertNil(ChatHeaderPolicy.participantInfo(loaded: nil, cached: nil))
    }

    // MARK: - The avatar

    /// A mailing list is drawn as the list's monogram in a group circle, whatever participant
    /// info is at hand: the row loads none for a list and shows none.
    ///
    /// Revert-check: passing `participantInfo?.avatarDisplayNames ?? []` and
    /// `participantInfo?.avatarPhotos ?? []` straight through in `ChatHeaderPolicy.avatar`, in
    /// place of the two `ConversationRowPolicy` calls, makes this fail.
    func testAvatar_mailingList_isAGroupCircleOfTheFallbackTextAlone() {
        let avatar = ChatHeaderPolicy.avatar(
            conversationType: .list,
            participantInfo: Self.info(names: ["First Sender"], photoURLs: ["https://example.com/a.png"]),
            fallbackDisplayText: "Swift Evolution"
        )

        XCTAssertTrue(avatar.participantNames.isEmpty)
        XCTAssertTrue(avatar.photos.isEmpty)
        XCTAssertTrue(avatar.showsGroupAvatar)
        XCTAssertEqual(avatar.fallbackDisplayText, "Swift Evolution")
    }

    /// Before the load lands, with nothing cached: one avatar for a one-to-one conversation,
    /// from the fallback text.
    ///
    /// Revert-check: passing `snapshotShowsGroupAvatar: true` in `ChatHeaderPolicy.avatar` makes
    /// this fail.
    func testAvatar_oneToOneWithNoInfo_isASingleAvatarOfTheFallbackText() {
        let avatar = ChatHeaderPolicy.avatar(
            conversationType: .oneToOne,
            participantInfo: nil,
            fallbackDisplayText: "Ada Lovelace"
        )

        XCTAssertTrue(avatar.participantNames.isEmpty)
        XCTAssertTrue(avatar.photos.isEmpty)
        XCTAssertFalse(avatar.showsGroupAvatar)
        XCTAssertEqual(avatar.fallbackDisplayText, "Ada Lovelace")
        XCTAssertEqual(
            AvatarStackView.resolvedLayout(
                participantCount: avatar.participantNames.count,
                showsGroupAvatar: avatar.showsGroupAvatar
            ),
            .single
        )
    }

    /// Before the load lands a group is already drawn as a group, as its row is
    /// (`ConversationSnapshot.showsGroupAvatar`), so the avatar does not change shape when the
    /// names arrive.
    ///
    /// Revert-check: passing `snapshotShowsGroupAvatar: false` in `ChatHeaderPolicy.avatar`
    /// makes this fail.
    func testAvatar_groupWithNoInfo_isAGroupCircle() {
        let avatar = ChatHeaderPolicy.avatar(
            conversationType: .group,
            participantInfo: nil,
            fallbackDisplayText: "Ada, Grace"
        )

        XCTAssertTrue(avatar.showsGroupAvatar)
        XCTAssertEqual(
            ConversationSnapshot.showsGroupAvatar(conversationType: .group),
            avatar.showsGroupAvatar
        )
    }

    /// The header's avatar is the row's: the same names and photos, slot for slot.
    ///
    /// Revert-check: passing `participantInfo: nil` to
    /// `ConversationRowPolicy.resolvedAvatarPhotos` in `ChatHeaderPolicy.avatar` makes this
    /// fail: the header would never show a photo.
    func testAvatar_loadedParticipants_areTheRowsNamesAndPhotos() {
        let info = Self.info(
            names: ["Ada Lovelace", "Grace Hopper", "Alan Turing"],
            photoURLs: ["https://example.com/ada.png", nil, "https://example.com/alan.png"],
            total: 3
        )

        let avatar = ChatHeaderPolicy.avatar(
            conversationType: .group,
            participantInfo: info,
            fallbackDisplayText: "Ada, Grace, Alan"
        )

        XCTAssertEqual(avatar.participantNames, ["Ada Lovelace", "Grace Hopper", "Alan Turing"])
        XCTAssertEqual(
            avatar.photos.map { $0?.url },
            ["https://example.com/ada.png", nil, "https://example.com/alan.png"]
        )
        XCTAssertTrue(avatar.showsGroupAvatar)
        XCTAssertEqual(
            avatar.participantNames,
            ConversationRowPolicy.resolvedAvatarDisplayNames(conversationType: .group, participantInfo: info)
        )
        XCTAssertEqual(
            avatar.photos.map { $0?.url },
            ConversationRowPolicy.resolvedAvatarPhotos(conversationType: .group, participantInfo: info)
                .map { $0?.url }
        )
    }

    /// A conversation stored as a group whose other participants come to one person once the
    /// user's own addresses are taken out is drawn as that person, as its row is.
    ///
    /// Revert-check: replacing the `ConversationRowPolicy.resolvedShowsGroupAvatar` call in
    /// `ChatHeaderPolicy.avatar` with `ConversationSnapshot.showsGroupAvatar(conversationType:)`
    /// alone makes this fail.
    func testAvatar_groupThatLoadsAsOnePerson_isASingleAvatar() {
        let avatar = ChatHeaderPolicy.avatar(
            conversationType: .group,
            participantInfo: Self.info(names: ["Ada Lovelace"], total: 1),
            fallbackDisplayText: "Ada Lovelace"
        )

        XCTAssertFalse(avatar.showsGroupAvatar)
        XCTAssertEqual(avatar.participantNames, ["Ada Lovelace"])
    }

    /// The fallback text is built by walking the conversation's participants in Core Data, and
    /// the header is re-evaluated with every update of the chat, so it is asked for only where
    /// the avatar can draw it.
    ///
    /// Revert-check: replacing the `readsFallbackDisplayText` condition in
    /// `ChatHeaderPolicy.avatar` with `true` makes this fail.
    func testAvatar_firstNameGivesInitials_doesNotAskForTheFallbackText() {
        var asked = 0
        func fallback() -> String {
            asked += 1
            return "Ada Lovelace"
        }

        let avatar = ChatHeaderPolicy.avatar(
            conversationType: .oneToOne,
            participantInfo: Self.info(names: ["Ada Lovelace"], total: 1),
            fallbackDisplayText: fallback()
        )

        XCTAssertEqual(asked, 0)
        XCTAssertNil(avatar.fallbackDisplayText)
    }

    /// A participant whose name gives no initials is drawn from the fallback text, as in the
    /// row (`SingleAvatarView.initialsSource`).
    ///
    /// Revert-check: replacing the `readsFallbackDisplayText` condition in
    /// `ChatHeaderPolicy.avatar` with `participantNames.isEmpty` makes this fail.
    func testAvatar_firstNameGivesNoInitials_keepsTheFallbackText() {
        let avatar = ChatHeaderPolicy.avatar(
            conversationType: .oneToOne,
            participantInfo: Self.info(names: ["   "], total: 1),
            fallbackDisplayText: "Ada Lovelace"
        )

        XCTAssertEqual(avatar.fallbackDisplayText, "Ada Lovelace")
    }

    /// The header leaves the fallback text out exactly where the avatar's views cannot draw
    /// it, whichever layout draws them: what each view draws with the text and without it is
    /// compared over names of every kind.
    ///
    /// Revert-check: returning `false` from `SingleAvatarView.readsFallbackDisplayText` makes
    /// this fail.
    ///
    /// HONEST SCOPE: returning `false` from `GroupAvatarView.readsFallbackDisplayText` does not.
    /// The group reads the text only with no participants, and there the single avatar's
    /// answer is already yes, so the header's answer does not change; the group circle itself
    /// would lose its monogram, which no test here draws.
    func testReadsFallbackDisplayText_isNoOnlyWhereNeitherAvatarViewDrawsTheText() {
        let fallback = "Zed Fallback"
        let lists: [[String]] = [
            [], ["Ada Lovelace"], ["   "], ["ada@example.com"], ["3 Unknown Contacts"],
            ["Ada Lovelace", "Grace Hopper"], ["   ", "Grace Hopper"]
        ]

        for names in lists {
            let singleDrawsIt = SingleAvatarView.resolvedContent(
                avatarPhoto: nil, participant: names.first, fallbackDisplayText: fallback
            ) != SingleAvatarView.resolvedContent(
                avatarPhoto: nil, participant: names.first, fallbackDisplayText: nil
            )
            // The group circle monograms the text only with no participants to draw.
            let groupDrawsIt = names.isEmpty
                && GroupAvatarView.resolvedEmptyContent(fallbackDisplayText: fallback) == .initials(fallback)

            XCTAssertEqual(
                ChatHeaderPolicy.readsFallbackDisplayText(participantNames: names),
                singleDrawsIt || groupDrawsIt,
                "\(names)"
            )
        }
    }

    // MARK: - The capsule's offset

    /// Half a point is one pixel at 2x and stays; at 1x it is half a pixel and goes to a whole
    /// one, so the name is not drawn across two pixel columns.
    ///
    /// Revert-check: returning `offset` unchanged from `ChatHeaderPolicy.pixelAlignedOffset`
    /// makes this fail.
    func testPixelAlignedOffset_isAWholeNumberOfTheDisplaysPixels() {
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(0.5, displayScale: 2), 0.5)
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(0.5, displayScale: 1), 1)
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(2.5, displayScale: 2), 2.5)
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(0.3, displayScale: 1), 0)
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(0.5, displayScale: 0), 0.5, "No scale: left as it is")
    }

    /// Revert-check: dropping `displayScale.isFinite` from the guard in
    /// `ChatHeaderPolicy.pixelAlignedOffset` makes this fail: the offset comes back NaN.
    func testPixelAlignedOffset_scaleThatIsNotANumber_leavesTheOffsetAsItIs() {
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(0.5, displayScale: .infinity), 0.5)
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(0.5, displayScale: .nan), 0.5)
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(0.5, displayScale: -2), 0.5)
        XCTAssertEqual(ChatHeaderPolicy.pixelAlignedOffset(.infinity, displayScale: 2), .infinity)
    }

    // MARK: - The Mac's metrics

    /// The numbers that were measured (`docs/mac-imessage-ui-plan.md`, "Spike results" and "PR 3
    /// as built"): a 40-point avatar fits the 52-point toolbar, the bar under it is 30 points,
    /// and the toolbar centers a principal item that has no glass behind it 0.5 points right of
    /// the chat column's center.
    ///
    /// Revert-check: changing `avatarDiameter`, `nameBarHeight` or `principalItemCenterOffset`
    /// in `ChatHeaderMetrics.mac` makes this fail.
    func testMacMetrics_areTheMeasuredNumbers() {
        XCTAssertEqual(ChatHeaderMetrics.mac.avatarDiameter, 40)
        XCTAssertEqual(ChatHeaderMetrics.mac.nameBarHeight, 30)
        XCTAssertEqual(ChatHeaderMetrics.mac.principalItemCenterOffset, 0.5)
    }

    /// The capsule stays more than 20 points from the chat column's edges, the distance at
    /// which an off-screen drawing lost the transcript under it
    /// (`ChatHeaderMetrics.nameBarHorizontalPadding`). The half point is the capsule's own
    /// shift toward one edge.
    ///
    /// Revert-check: setting `nameBarHorizontalPadding` to 16 in `ChatHeaderMetrics.mac` makes
    /// this fail.
    func testMacMetrics_theCapsuleStaysClearOfTheColumnsEdges() {
        XCTAssertGreaterThanOrEqual(
            ChatHeaderMetrics.mac.nameBarHorizontalPadding - ChatHeaderMetrics.mac.principalItemCenterOffset,
            22
        )
    }

    /// The capsule has to fit inside its bar, or the bar's fixed height would clip it.
    ///
    /// Revert-check: setting `nameCapsuleHeight` above `nameBarHeight` in
    /// `ChatHeaderMetrics.mac` makes this fail.
    func testMacMetrics_theCapsuleFitsInsideItsBar() {
        XCTAssertLessThanOrEqual(
            ChatHeaderMetrics.mac.nameCapsuleHeight,
            ChatHeaderMetrics.mac.nameBarHeight
        )
    }

    // MARK: - Fixtures

    private static func info(
        names: [String],
        photoURLs: [String?] = [],
        total: Int? = nil
    ) -> ParticipantLoader.ParticipantInfo {
        let photos = photoURLs.map { url in
            url.map { ProfilePhoto(source: .cached, imageData: nil, url: $0) }
        }
        return ParticipantLoader.ParticipantInfo(
            emails: names.indices.map { "person\($0)@example.com" },
            displayNames: names,
            photos: photos.compactMap { $0 },
            formattedDisplayName: names.joined(separator: ", "),
            totalUniqueParticipants: total ?? names.count,
            avatarDisplayNames: names,
            avatarPhotos: photoURLs.isEmpty ? nil : photos
        )
    }

    private static func metrics(avatarDiameter: CGFloat) -> ChatHeaderMetrics {
        ChatHeaderMetrics(
            avatarDiameter: avatarDiameter,
            nameBarHeight: ChatHeaderMetrics.mac.nameBarHeight,
            nameCapsuleHeight: ChatHeaderMetrics.mac.nameCapsuleHeight,
            nameCapsuleHorizontalPadding: ChatHeaderMetrics.mac.nameCapsuleHorizontalPadding,
            nameBarHorizontalPadding: ChatHeaderMetrics.mac.nameBarHorizontalPadding,
            nameFont: ChatHeaderMetrics.mac.nameFont,
            nameToChevronSpacing: ChatHeaderMetrics.mac.nameToChevronSpacing,
            chevronFont: ChatHeaderMetrics.mac.chevronFont,
            principalItemCenterOffset: ChatHeaderMetrics.mac.principalItemCenterOffset
        )
    }
}
