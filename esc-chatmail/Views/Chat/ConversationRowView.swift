import SwiftUI
import CoreData

/// Snapshot of conversation data to prevent excessive re-renders.
/// Instead of observing the full Conversation object (which triggers re-renders on ANY property change),
/// we capture only the display-relevant properties once and update via explicit refresh.
struct ConversationSnapshot: Equatable {
    let objectID: NSManagedObjectID
    let inboxUnreadCount: Int32
    let pinned: Bool
    let snippet: String?
    let lastMessageDate: Date?
    let displayNameHint: String?

    init(from conversation: Conversation) {
        self.objectID = conversation.objectID
        self.inboxUnreadCount = conversation.inboxUnreadCount
        self.pinned = conversation.pinned
        self.snippet = conversation.snippet
        self.lastMessageDate = conversation.lastMessageDate
        self.displayNameHint = conversation.displayName
    }
}

struct ConversationRowView: View {
    /// Use snapshot to avoid re-renders from unrelated Conversation property changes
    let snapshot: ConversationSnapshot
    /// Keep reference for participant loading (but don't observe it)
    let conversation: Conversation

    private let authSession = AuthSession.shared
    private let personCache = PersonCache.shared

    @State private var displayName: String = ""
    @State private var avatarPhotos: [ProfilePhoto] = []
    @State private var participantNames: [String] = []

    init(conversation: Conversation) {
        self.conversation = conversation
        self.snapshot = ConversationSnapshot(from: conversation)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Unread indicator with fixed width container
            ZStack {
                if snapshot.inboxUnreadCount > 0 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 10, height: 10)

            // Avatar stack
            AvatarStackView(avatarPhotos: avatarPhotos, participants: participantNames)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                // Top row: Name, date, and chevron
                HStack {
                    HStack(spacing: 4) {
                        if snapshot.pinned {
                            Image(systemName: "pin.fill")
                                .font(.footnote)
                                .foregroundColor(.orange)
                        }

                        Text(displayName)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        if let date = snapshot.lastMessageDate {
                            Text(formatDate(date))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(.tertiaryLabel))
                    }
                }

                // Bottom row: snippet only
                Text(snapshot.snippet ?? "No messages")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(height: 96)
        .padding(.horizontal, 12)
        .task(priority: .medium) {
            await loadContactInfo()
        }
    }

    private func loadContactInfo() async {
        // Small yield to avoid blocking UI interactions
        await Task.yield()

        guard let participants = conversation.participants else {
            displayName = "Unknown"
            return
        }

        let myEmail = authSession.userEmail ?? ""
        let normalizedMyEmail = EmailNormalizer.normalize(myEmail)

        // Get non-me participants
        let nonMeParticipants = participants.compactMap { participant -> String? in
            guard let email = participant.person?.email else { return nil }
            let normalized = EmailNormalizer.normalize(email)
            return normalized != normalizedMyEmail ? email : nil
        }

        // Limit to top 4 participants for display (for group avatar)
        let topParticipants = Array(nonMeParticipants.prefix(4))

        // Check if all emails are already cached (ViewModel likely prefetched them)
        let allCached = topParticipants.allSatisfy { email in
            personCache.getCachedDisplayName(for: email) != nil
        }

        // Only call prefetch if we have uncached emails (avoids redundant calls)
        if !allCached {
            await personCache.prefetch(emails: topParticipants)
        }

        // Now get names from cache (all should be cached after prefetch)
        var resolvedNames: [String] = []
        for email in topParticipants {
            let name = personCache.getCachedDisplayName(for: email) ?? fallbackDisplayName(for: email)
            resolvedNames.append(name)
        }

        // Update display name immediately (before photos load)
        updateDisplayName(resolvedNames: resolvedNames, totalParticipants: nonMeParticipants.count)
        participantNames = resolvedNames

        // Load photos separately (slower, may involve network)
        let photoResults = await ProfilePhotoResolver.shared.resolvePhotos(for: topParticipants)
        var resolvedPhotos: [ProfilePhoto] = []
        for email in topParticipants {
            let normalizedEmail = EmailNormalizer.normalize(email)
            if let photo = photoResults[normalizedEmail] {
                resolvedPhotos.append(photo)
            }
        }
        avatarPhotos = resolvedPhotos
    }

    private func updateDisplayName(resolvedNames: [String], totalParticipants: Int) {
        if resolvedNames.isEmpty {
            displayName = conversation.displayName ?? "No participants"
        } else if resolvedNames.count == 1 {
            displayName = resolvedNames[0]
        } else {
            let firstNames = resolvedNames.map { name in
                let components = name.components(separatedBy: " ")
                return components.first ?? name
            }

            if firstNames.count == 2 {
                displayName = "\(firstNames[0]), \(firstNames[1])"
            } else {
                let remaining = totalParticipants - 2
                if remaining > 0 {
                    displayName = "\(firstNames[0]), \(firstNames[1]) +\(remaining)"
                } else {
                    displayName = "\(firstNames[0]), \(firstNames[1])"
                }
            }
        }
    }

    private func fallbackDisplayName(for email: String) -> String {
        // Preserve original case for display, just extract username part
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let atIndex = trimmed.firstIndex(of: "@") {
            return String(trimmed[..<atIndex])
        }
        return trimmed
    }

    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}

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
                size: 50
            ) {
                if let participant = participant {
                    InitialsView(name: participant)
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundColor(.gray)
                }
            }
        } else if let participant = participant {
            InitialsView(name: participant)
                .frame(width: 50, height: 50)
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: 50, height: 50)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Group Avatar View (iMessage style)

struct GroupAvatarView: View {
    let avatarPhotos: [ProfilePhoto]
    let participants: [String]

    private let mainSize: CGFloat = 50
    private let smallSize: CGFloat = 22
    private let positions: [(x: CGFloat, y: CGFloat)] = [
        (x: -9, y: -9),   // Top left
        (x: 9, y: -9),    // Top right
        (x: 9, y: 9),     // Bottom right
        (x: -9, y: 9)     // Bottom left
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
                        SmallInitialsView(name: participants[index])
                            .frame(width: smallSize, height: smallSize)
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
            return index == 0 ? -9 : 9
        case 3:
            // Three avatars: triangle arrangement
            switch index {
            case 0: return 0      // Top center
            case 1: return -9     // Bottom left
            case 2: return 9      // Bottom right
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
            case 0: return -9     // Top
            case 1, 2: return 9   // Bottom
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
                SmallInitialsView(name: name)
                    .frame(width: size, height: size)
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

// MARK: - Small Initials View for Group Avatars

struct SmallInitialsView: View {
    let name: String

    private var initials: String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            let first = String(components[0].prefix(1))
            let last = String(components[1].prefix(1))
            return (first + last).uppercased()
        } else if let first = components.first {
            return String(first.prefix(1)).uppercased()
        }
        return "?"
    }

    private var backgroundColor: Color {
        // Generate consistent color based on name
        let hash = name.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.8)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)

            Text(initials)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
        }
        .overlay(
            Circle()
                .stroke(Color(UIColor.systemBackground), lineWidth: 1.5)
        )
    }
}

// MARK: - Initials View

struct InitialsView: View {
    let name: String
    
    private var initials: String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            let first = String(components[0].prefix(1))
            let last = String(components[1].prefix(1))
            return (first + last).uppercased()
        } else if let first = components.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
    
    private var backgroundColor: Color {
        // Generate consistent color based on name
        let hash = name.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.8)
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
            
            Text(initials)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.white)
        }
        .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }
}