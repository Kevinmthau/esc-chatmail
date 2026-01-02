import SwiftUI

// MARK: - Avatar Stack View

struct AvatarStackView: View {
    let avatarPhotos: [ProfilePhoto]
    let participants: [String]

    var body: some View {
        if participants.count > 1 {
            // Group conversation - show multiple small avatars in a circle
            GroupAvatarView(avatarPhotos: avatarPhotos, participants: participants)
        } else {
            // Single conversation - show single large avatar
            SingleAvatarView(avatarPhoto: avatarPhotos.first, participant: participants.first)
        }
    }
}

// MARK: - Single Avatar View

struct SingleAvatarView: View {
    let avatarPhoto: ProfilePhoto?
    let participant: String?

    var body: some View {
        if let photo = avatarPhoto {
            CachedAsyncImage(
                imageData: photo.imageData,
                imageURL: photo.url,
                size: 44
            ) {
                if let participant = participant {
                    InitialsAvatarView(name: participant, style: .standard)
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundColor(.gray)
                }
            }
        } else if let participant = participant {
            InitialsAvatarView(name: participant, style: .standard)
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: 44, height: 44)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Group Avatar View (iMessage style)

struct GroupAvatarView: View {
    let avatarPhotos: [ProfilePhoto]
    let participants: [String]

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

            // Show up to 4 small avatars
            let maxAvatars = min(4, participants.count)

            ForEach(0..<maxAvatars, id: \.self) { index in
                ZStack {
                    if index < avatarPhotos.count {
                        // Show actual avatar image
                        SmallCachedAvatarView(
                            photo: avatarPhotos[index],
                            name: index < participants.count ? participants[index] : nil,
                            size: smallSize
                        )
                    } else if index < participants.count {
                        // Show initials
                        InitialsAvatarView(name: participants[index], style: .compact)
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
