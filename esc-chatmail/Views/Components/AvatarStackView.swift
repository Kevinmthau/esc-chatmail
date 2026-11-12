import SwiftUI

// MARK: - Avatar Stack View

struct AvatarStackView: View {
    /// The diameter the avatar drawings were designed at, and the iOS list's. Every size
    /// inside them (the small avatars of a group, their offsets, the initials' font) is given
    /// at this diameter and scales with `diameter`.
    static let designDiameter: CGFloat = 44

    let avatarPhotos: [ProfilePhoto?]
    let participants: [String]
    let showsGroupAvatar: Bool
    let fallbackDisplayText: String?
    /// The avatar's diameter. The Mac sidebar's is smaller than the iOS list's
    /// (`ConversationRowMetrics`).
    let diameter: CGFloat
    /// A group avatar's disc and rings: `.standard` unless the avatar sits on the Mac
    /// sidebar's selection fill (`ConversationRowPalette`).
    let groupColors: GroupAvatarColors

    init(
        avatarPhotos: [ProfilePhoto],
        participants: [String],
        showsGroupAvatar: Bool = false,
        fallbackDisplayText: String? = nil,
        diameter: CGFloat = AvatarStackView.designDiameter,
        groupColors: GroupAvatarColors = .standard
    ) {
        self.init(
            alignedAvatarPhotos: avatarPhotos.map(Optional.some),
            participants: participants,
            showsGroupAvatar: showsGroupAvatar,
            fallbackDisplayText: fallbackDisplayText,
            diameter: diameter,
            groupColors: groupColors
        )
    }

    init(
        alignedAvatarPhotos: [ProfilePhoto?],
        participants: [String],
        showsGroupAvatar: Bool = false,
        fallbackDisplayText: String? = nil,
        diameter: CGFloat = AvatarStackView.designDiameter,
        groupColors: GroupAvatarColors = .standard
    ) {
        self.avatarPhotos = alignedAvatarPhotos
        self.participants = participants
        self.showsGroupAvatar = showsGroupAvatar
        self.fallbackDisplayText = fallbackDisplayText
        self.diameter = diameter
        self.groupColors = groupColors
    }

    var body: some View {
        if Self.resolvedLayout(
            participantCount: participants.count,
            showsGroupAvatar: showsGroupAvatar
        ) == .group {
            // Group conversation - show multiple small avatars in a circle
            GroupAvatarView(
                avatarPhotos: avatarPhotos,
                participants: participants,
                fallbackDisplayText: fallbackDisplayText,
                diameter: diameter,
                colors: groupColors
            )
        } else {
            // Single conversation - show single large avatar
            SingleAvatarView(
                avatarPhoto: avatarPhotos.first ?? nil,
                participant: participants.first,
                fallbackDisplayText: fallbackDisplayText,
                diameter: diameter
            )
        }
    }
}

extension AvatarStackView {
    /// Whether an avatar of these participants can draw from its fallback text at all, in
    /// either layout. False means the text is never drawn, so a caller for whom the text is
    /// costly need not build it (`ChatHeaderPolicy.avatar`).
    ///
    /// Made of the two views' own answers, never restated: a view that comes to read the
    /// fallback in another case changes its answer, and every caller follows.
    static func readsFallbackDisplayText(participants: [String]) -> Bool {
        SingleAvatarView.readsFallbackDisplayText(participant: participants.first)
            || GroupAvatarView.readsFallbackDisplayText(participants: participants)
    }

    enum Layout: Equatable {
        case single
        case group
    }

    static func resolvedLayout(
        participantCount: Int,
        showsGroupAvatar: Bool
    ) -> Layout {
        if showsGroupAvatar || participantCount > 1 {
            return .group
        }

        return .single
    }
}

// MARK: - Single Avatar View

struct SingleAvatarView: View {
    let avatarPhoto: ProfilePhoto?
    let participant: String?
    let fallbackDisplayText: String?
    let diameter: CGFloat

    init(
        avatarPhoto: ProfilePhoto?,
        participant: String?,
        fallbackDisplayText: String? = nil,
        diameter: CGFloat = AvatarStackView.designDiameter
    ) {
        self.avatarPhoto = avatarPhoto
        self.participant = participant
        self.fallbackDisplayText = fallbackDisplayText
        self.diameter = diameter
    }

    var body: some View {
        let initialsSource = Self.initialsSource(
            participant: participant,
            fallbackDisplayText: fallbackDisplayText
        )

        if let photo = avatarPhoto {
            CachedAsyncImage(
                imageData: photo.imageData,
                imageURL: photo.url,
                size: diameter
            ) {
                fallbackAvatarView(initialsSource: initialsSource)
            }
        } else {
            fallbackAvatarView(initialsSource: initialsSource)
        }
    }

    @ViewBuilder
    private func fallbackAvatarView(initialsSource: String?) -> some View {
        if let initialsSource {
            InitialsAvatarView(name: initialsSource, style: .standard.scaled(to: diameter))
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: diameter, height: diameter)
                .foregroundColor(.gray)
        }
    }
}

extension SingleAvatarView {
    // Compiled once, with no options: the per-call site passed only
    // `.regularExpression`, so this stays case-sensitive. It runs per
    // conversation row body on the main thread.
    private static let unknownContactsCountRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^\d+\s+unknown contacts?$"#)
    }()

    enum AvatarContent: Equatable {
        case photo
        case initials(String)
        case genericIcon
    }

    static func resolvedContent(
        avatarPhoto: ProfilePhoto?,
        participant: String?,
        fallbackDisplayText: String?
    ) -> AvatarContent {
        if avatarPhoto != nil {
            return .photo
        }

        if let initialsSource = initialsSource(
            participant: participant,
            fallbackDisplayText: fallbackDisplayText
        ) {
            return .initials(initialsSource)
        }

        return .genericIcon
    }

    /// Whether the single avatar's initials can come from the fallback text: only where the
    /// participant's own name gives none (`initialsSource` takes the first usable of the two).
    static func readsFallbackDisplayText(participant: String?) -> Bool {
        usableIdentityText(from: participant) == nil
    }

    static func initialsSource(
        participant: String?,
        fallbackDisplayText: String?
    ) -> String? {
        [participant, fallbackDisplayText]
            .compactMap(usableIdentityText(from:))
            .first
    }

    static func usableIdentityText(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalizedWhitespace = RegexSanitizer.replace(in: trimmed, regex: RegexSanitizer.whitespaceRunRegex, with: " ")

        guard !isPlaceholderDisplayName(normalizedWhitespace) else {
            return nil
        }

        if let displayName = EmailNormalizer.extractDisplayName(from: normalizedWhitespace)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }

        if let email = EmailNormalizer.extractEmail(from: normalizedWhitespace)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }

        return normalizedWhitespace
    }

    private static func isPlaceholderDisplayName(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard !placeholderDisplayNames.contains(lowercased) else { return true }
        guard let regex = unknownContactsCountRegex else { return false }
        let range = NSRange(location: 0, length: lowercased.utf16.count)
        return regex.firstMatch(in: lowercased, options: [], range: range) != nil
    }

    private static let placeholderDisplayNames: Set<String> = [
        "no participants",
        "unknown",
        "unknown contact",
        "unknown contacts",
        "unknown sender"
    ]
}

// MARK: - Group Avatar View (iMessage style)

struct GroupAvatarView: View {
    let avatarPhotos: [ProfilePhoto?]
    let participants: [String]
    let fallbackDisplayText: String?
    /// The whole avatar's diameter. `smallSize` and `offset` follow it.
    let mainSize: CGFloat
    /// The disc and the small avatars' rings, which depend on what the avatar sits on.
    let colors: GroupAvatarColors

    init(
        avatarPhotos: [ProfilePhoto?],
        participants: [String],
        fallbackDisplayText: String? = nil,
        diameter: CGFloat = AvatarStackView.designDiameter,
        colors: GroupAvatarColors = .standard
    ) {
        self.avatarPhotos = avatarPhotos
        self.participants = participants
        self.fallbackDisplayText = fallbackDisplayText
        self.mainSize = diameter
        self.colors = colors
    }

    /// 1 at the design diameter, where every size below is the number it is written as.
    private var scale: CGFloat { mainSize / AvatarStackView.designDiameter }
    /// A small avatar's diameter: 20 points at the design diameter.
    private var smallSize: CGFloat { 20 * scale }
    /// How far a small avatar sits from the center, along each axis: 8 points at the design
    /// diameter.
    private var offset: CGFloat { 8 * scale }
    /// The small avatars' places for a group of four, as multiples of `offset`.
    private let positions: [(x: CGFloat, y: CGFloat)] = [
        (x: -1, y: -1),   // Top left
        (x: 1, y: -1),    // Top right
        (x: 1, y: 1),     // Bottom right
        (x: -1, y: 1)     // Bottom left
    ]

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(colors.disc)
                .frame(width: mainSize, height: mainSize)

            // No resolved participants (load pending or failed): monogram the
            // fallback title like SingleAvatarView does, never a blank circle.
            if Self.readsFallbackDisplayText(participants: participants),
               case .initials(let initialsSource) = Self.resolvedEmptyContent(
                    fallbackDisplayText: fallbackDisplayText
               ) {
                InitialsAvatarView(name: initialsSource, style: .standard.scaled(to: mainSize))
            }

            // Show up to 4 small avatars
            let maxAvatars = min(4, participants.count)

            ForEach(0..<maxAvatars, id: \.self) { index in
                ZStack {
                    if index < avatarPhotos.count, let avatarPhoto = avatarPhotos[index] {
                        // Show actual avatar image
                        SmallCachedAvatarView(
                            photo: avatarPhoto,
                            name: index < participants.count ? participants[index] : nil,
                            size: smallSize,
                            ringColor: colors.ring
                        )
                    } else if index < participants.count,
                              let initialsSource = SingleAvatarView.usableIdentityText(from: participants[index]) {
                        // Show initials
                        InitialsAvatarView(
                            name: initialsSource,
                            style: .compact.scaled(to: smallSize).bordered(in: colors.ring)
                        )
                    } else {
                        // Fallback to person icon
                        Circle()
                            .fill(Color.systemGray4)
                            .frame(width: smallSize, height: smallSize)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 12 * scale))
                                    .foregroundColor(.white)
                            )
                            .overlay(
                                Circle()
                                    .stroke(colors.ring, lineWidth: 1.5)
                            )
                    }
                }
                .offset(
                    x: getPositionX(index: index, total: maxAvatars),
                    y: getPositionY(index: index, total: maxAvatars)
                )
            }
        }
        .frame(width: mainSize, height: mainSize)
    }

    private func getPositionX(index: Int, total: Int) -> CGFloat {
        switch total {
        case 2:
            // Two avatars: left and right
            return index == 0 ? -offset : offset
        case 3:
            // Three avatars: triangle arrangement
            switch index {
            case 0: return 0           // Top center
            case 1: return -offset     // Bottom left
            case 2: return offset      // Bottom right
            default: return 0
            }
        case 4:
            // Four avatars: corners
            return positions[index].x * offset
        default:
            return 0
        }
    }

    private func getPositionY(index: Int, total: Int) -> CGFloat {
        switch total {
        case 2:
            // Two avatars: centered vertically
            return 0
        case 3:
            // Three avatars: triangle arrangement
            switch index {
            case 0: return -offset     // Top
            case 1, 2: return offset   // Bottom
            default: return 0
            }
        case 4:
            // Four avatars: corners
            return positions[index].y * offset
        default:
            return 0
        }
    }
}

extension GroupAvatarView {
    /// No options: the per-call site passed only `.regularExpression`.
    private static let overflowCountSuffixRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s*\+\d+\s*$"#)
    }()

    enum EmptyGroupContent: Equatable {
        case initials(String)
        case placeholderCircle
    }

    /// Whether the group circle draws from the fallback text: only with no participants,
    /// where it monograms the text (`resolvedEmptyContent`). The body asks this.
    static func readsFallbackDisplayText(participants: [String]) -> Bool {
        participants.isEmpty
    }

    /// Monogram source for a group circle with no resolved participants —
    /// parity with SingleAvatarView's fallback so a pending or failed
    /// participant load degrades to initials instead of a blank gray circle.
    static func resolvedEmptyContent(fallbackDisplayText: String?) -> EmptyGroupContent {
        // "+N" overflow suffixes are counts, not names; drop them before monogramming.
        let strippedOverflow = fallbackDisplayText.map {
            RegexSanitizer.replace(in: $0, regex: overflowCountSuffixRegex, with: "")
        }
        guard let initialsSource = SingleAvatarView.usableIdentityText(from: strippedOverflow) else {
            return .placeholderCircle
        }
        return .initials(initialsSource)
    }
}

// MARK: - Small Cached Avatar View for Group Avatars

struct SmallCachedAvatarView: View {
    let photo: ProfilePhoto
    let name: String?
    let size: CGFloat
    /// The ring around the avatar, in the group's color for it (`GroupAvatarColors.ring`).
    let ringColor: Color

    var body: some View {
        CachedAsyncImage(
            imageData: photo.imageData,
            imageURL: photo.url,
            size: size,
            showsProgressWhileLoading: false,
            imageBorderColor: ringColor,
            imageBorderWidth: 1.5
        ) {
            if let name {
                InitialsAvatarView(name: name, style: .compact.scaled(to: size).bordered(in: ringColor))
            } else {
                Circle()
                    .fill(Color.systemGray4)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.5))
                            .foregroundColor(.white)
                    )
                    .overlay(
                        Circle()
                            .stroke(ringColor, lineWidth: 1.5)
                    )
            }
        }
    }
}
