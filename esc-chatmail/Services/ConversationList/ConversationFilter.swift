import Foundation

/// Filter options for the conversation list
enum ConversationFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
    case contacts = "Contacts"
    case other = "Other"

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .unread: return "envelope.badge"
        case .contacts: return "person.crop.circle"
        case .other: return "person.crop.circle.badge.questionmark"
        }
    }
}
