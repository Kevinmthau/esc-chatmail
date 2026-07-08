import SwiftUI

// MARK: - Avatar Stack View

struct AvatarStackView: View {
    let avatarPhotos: [ProfilePhoto?]
    let participants: [String]
    let showsGroupAvatar: Bool
    let fallbackDisplayText: String?

    init(
        avatarPhotos: [ProfilePhoto],
        participants: [String],
        showsGroupAvatar: Bool = false,
        fallbackDisplayText: String? = nil
    ) {
        self.init(
            alignedAvatarPhotos: avatarPhotos.map(Optional.some),
            participants: participants,
            showsGroupAvatar: showsGroupAvatar,
            fallbackDisplayText: fallbackDisplayText
        )
    }

    init(
        alignedAvatarPhotos: [ProfilePhoto?],
        participants: [String],
        showsGroupAvatar: Bool = false,
        fallbackDisplayText: String? = nil
    ) {
        self.avatarPhotos = alignedAvatarPhotos
        self.participants = participants
        self.showsGroupAvatar = showsGroupAvatar
        self.fallbackDisplayText = fallbackDisplayText
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
                fallbackDisplayText: fallbackDisplayText
            )
        } else {
            // Single conversation - show single large avatar
            SingleAvatarView(
                avatarPhoto: avatarPhotos.first ?? nil,
                participant: participants.first,
                fallbackDisplayText: fallbackDisplayText
            )
        }
    }
}

extension AvatarStackView {
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

    init(
        avatarPhoto: ProfilePhoto?,
        participant: String?,
        fallbackDisplayText: String? = nil
    ) {
        self.avatarPhoto = avatarPhoto
        self.participant = participant
        self.fallbackDisplayText = fallbackDisplayText
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
                size: 44
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
            InitialsAvatarView(name: initialsSource, style: .standard)
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: 44, height: 44)
                .foregroundColor(.gray)
        }
    }
}

extension SingleAvatarView {
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

        let normalizedWhitespace = trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

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
        return placeholderDisplayNames.contains(lowercased)
            || lowercased.range(
                of: #"^\d+\s+unknown contacts?$"#,
                options: .regularExpression
            ) != nil
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

    init(
        avatarPhotos: [ProfilePhoto?],
        participants: [String],
        fallbackDisplayText: String? = nil
    ) {
        self.avatarPhotos = avatarPhotos
        self.participants = participants
        self.fallbackDisplayText = fallbackDisplayText
    }

    private let mainSize: CGFloat = 44
    private let smallSize: CGFloat = 20
    private let positions: [(x: CGFloat, y: CGFloat)] = [
        (x: -8, y: -8),   // Top left
        (x: 8, y: -8),    // Top right
        (x: 8, y: 8),     // Bottom right
        (x: -8, y: 8)     // Bottom left
    ]

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color(UIColor.systemGray6))
                .frame(width: mainSize, height: mainSize)

            // No resolved participants (load pending or failed): monogram the
            // fallback title like SingleAvatarView does, never a blank circle.
            if participants.isEmpty,
               case .initials(let initialsSource) = Self.resolvedEmptyContent(
                    fallbackDisplayText: fallbackDisplayText
               ) {
                InitialsAvatarView(name: initialsSource, style: .standard)
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
                            size: smallSize
                        )
                    } else if index < participants.count,
                              let initialsSource = SingleAvatarView.usableIdentityText(from: participants[index]) {
                        // Show initials
                        InitialsAvatarView(name: initialsSource, style: .compact)
                    } else {
                        // Fallback to person icon
                        Circle()
                            .fill(Color(UIColor.systemGray4))
                            .frame(width: smallSize, height: smallSize)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color(UIColor.systemBackground), lineWidth: 1.5)
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
            return index == 0 ? -8 : 8
        case 3:
            // Three avatars: triangle arrangement
            switch index {
            case 0: return 0      // Top center
            case 1: return -8     // Bottom left
            case 2: return 8      // Bottom right
            default: return 0
            }
        case 4:
            // Four avatars: corners
            return positions[index].x
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
            case 0: return -8     // Top
            case 1, 2: return 8   // Bottom
            default: return 0
            }
        case 4:
            // Four avatars: corners
            return positions[index].y
        default:
            return 0
        }
    }
}

extension GroupAvatarView {
    enum EmptyGroupContent: Equatable {
        case initials(String)
        case placeholderCircle
    }

    /// Monogram source for a group circle with no resolved participants —
    /// parity with SingleAvatarView's fallback so a pending or failed
    /// participant load degrades to initials instead of a blank gray circle.
    static func resolvedEmptyContent(fallbackDisplayText: String?) -> EmptyGroupContent {
        // "+N" overflow suffixes are counts, not names; drop them before monogramming.
        let strippedOverflow = fallbackDisplayText?.replacingOccurrences(
            of: #"\s*\+\d+\s*$"#,
            with: "",
            options: .regularExpression
        )
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

    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color(UIColor.systemBackground), lineWidth: 1.5)
                    )
            } else if let name = name {
                InitialsAvatarView(name: name, style: .compact)
            } else {
                Circle()
                    .fill(Color(UIColor.systemGray4))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.5))
                            .foregroundColor(.white)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color(UIColor.systemBackground), lineWidth: 1.5)
                    )
            }
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        // Try imageData first (decode on background thread)
        if let data = photo.imageData {
            if let image = await ImageDecoder.decodeAsync(data) {
                await MainActor.run {
                    loadedImage = image
                }
                return
            }
        }

        // Try URL - use enhanced cache (handles all URL types with disk caching)
        guard let urlString = photo.url, !urlString.isEmpty else { return }

        if let image = await EnhancedImageCache.shared.loadImage(from: urlString) {
            await MainActor.run {
                loadedImage = image
            }
        }
    }
}
