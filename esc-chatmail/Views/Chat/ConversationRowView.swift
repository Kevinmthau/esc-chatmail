import SwiftUI
import CoreData

struct ConversationRowView: View {
    let conversation: Conversation
    @StateObject private var contactsResolver = ContactsResolver.shared
    @StateObject private var authSession = AuthSession.shared
    
    @State private var displayName: String = ""
    @State private var avatarData: [Data] = []
    @State private var participantNames: [String] = []
    
    var body: some View {
        HStack(spacing: 8) {
            // Unread indicator with fixed width container
            ZStack {
                if conversation.inboxUnreadCount > 0 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 10, height: 10)

            // Avatar stack
            AvatarStackView(avatarData: avatarData, participants: participantNames)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                // Top row: Name, date, and chevron
                HStack {
                    HStack(spacing: 4) {
                        if conversation.pinned {
                            Image(systemName: "pin.fill")
                                .font(.footnote)
                                .foregroundColor(.orange)
                        }

                        Text(displayName)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let date = conversation.lastMessageDate {
                        HStack(spacing: 4) {
                            Text(formatDate(date))
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.medium))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                }

                // Bottom row: snippet only
                Text(conversation.snippet ?? "No messages")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task {
            await loadContactInfo()
        }
    }
    
    private func loadContactInfo() async {
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
        
        // Resolve names and avatars
        var resolvedNames: [String] = []
        var resolvedAvatars: [Data] = []
        
        for email in topParticipants {
            // Try contacts first
            if let match = await contactsResolver.lookup(email: email) {
                if let name = match.displayName {
                    resolvedNames.append(name)
                } else {
                    // Fallback to Person displayName or email
                    resolvedNames.append(getPersonDisplayName(for: email))
                }
                
                if let imageData = match.imageData {
                    resolvedAvatars.append(imageData)
                }
            } else {
                // Fallback to Person displayName or email
                resolvedNames.append(getPersonDisplayName(for: email))
            }
        }
        
        // Build display name
        if resolvedNames.isEmpty {
            displayName = conversation.displayName ?? "No participants"
        } else if resolvedNames.count == 1 {
            displayName = resolvedNames[0]
        } else if resolvedNames.count == 2 {
            displayName = "\(resolvedNames[0]), \(resolvedNames[1])"
        } else {
            let remaining = nonMeParticipants.count - 2
            if remaining > 0 {
                displayName = "\(resolvedNames[0]), \(resolvedNames[1]) +\(remaining)"
            } else {
                displayName = "\(resolvedNames[0]), \(resolvedNames[1])"
            }
        }
        
        participantNames = resolvedNames
        avatarData = resolvedAvatars
    }
    
    private func getPersonDisplayName(for email: String) -> String {
        let normalized = EmailNormalizer.normalize(email)
        
        // Try to get from Core Data Person
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", normalized)
        request.fetchLimit = 1
        
        if let person = try? CoreDataStack.shared.viewContext.fetch(request).first,
           let displayName = person.displayName,
           !displayName.isEmpty {
            return displayName
        }
        
        // Fallback to email local part
        if let atIndex = normalized.firstIndex(of: "@") {
            return String(normalized[..<atIndex])
        }
        
        return email
    }
    
    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}

// MARK: - Avatar Stack View

struct AvatarStackView: View {
    let avatarData: [Data]
    let participants: [String]

    var body: some View {
        if participants.count > 1 {
            // Group conversation - show multiple small avatars in a circle
            GroupAvatarView(avatarData: avatarData, participants: participants)
        } else {
            // Single conversation - show single large avatar
            SingleAvatarView(avatarData: avatarData.first, participant: participants.first)
        }
    }
}

// MARK: - Single Avatar View

struct SingleAvatarView: View {
    let avatarData: Data?
    let participant: String?

    var body: some View {
        if let avatarData = avatarData,
           let uiImage = UIImage(data: avatarData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
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
    let avatarData: [Data]
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
                    if index < avatarData.count,
                       let uiImage = UIImage(data: avatarData[index]) {
                        // Show actual avatar image
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: smallSize, height: smallSize)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color(UIColor.systemBackground), lineWidth: 1.5)
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