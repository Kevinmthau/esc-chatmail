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
        HStack(spacing: 12) {
            // Avatar stack
            AvatarStackView(avatarData: avatarData, participants: participantNames)
                .frame(width: 60, height: 60)
            
            VStack(alignment: .leading, spacing: 3) {
                // Top row: Name, date, and chevron
                HStack {
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    
                    Text(displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if let date = conversation.lastMessageDate {
                        HStack(spacing: 4) {
                            Text(formatDate(date))
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                }
                
                // Bottom row: Unread indicator and snippet
                HStack(spacing: 6) {
                    if conversation.inboxUnreadCount > 0 {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 10, height: 10)
                    }
                    
                    Text(conversation.snippet ?? "No messages")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        
        // Limit to top 3 participants for display
        let topParticipants = Array(nonMeParticipants.prefix(3))
        
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
        ZStack {
            if !avatarData.isEmpty {
                // Show actual avatars
                ForEach(0..<min(avatarData.count, 2), id: \.self) { index in
                    if let uiImage = UIImage(data: avatarData[index]) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .offset(x: CGFloat(index) * 15)
                    }
                }
            } else if !participants.isEmpty {
                // Show initials
                ForEach(0..<min(participants.count, 2), id: \.self) { index in
                    InitialsView(name: participants[index])
                        .frame(width: 40, height: 40)
                        .offset(x: CGFloat(index) * 15)
                }
            } else {
                // Default avatar
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 60, height: 60)
                    .foregroundColor(.gray)
            }
        }
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
        .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }
}