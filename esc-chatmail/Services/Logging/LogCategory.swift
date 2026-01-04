import Foundation

// MARK: - Log Category

/// Categories for filtering and organizing logs
enum LogCategory: String {
    case sync = "Sync"
    case api = "API"
    case coreData = "CoreData"
    case auth = "Auth"
    case ui = "UI"
    case attachment = "Attachment"
    case message = "Message"
    case conversation = "Conversation"
    case background = "Background"
    case performance = "Performance"
    case general = "General"

    var subsystem: String {
        "com.esc.chatmail.\(rawValue.lowercased())"
    }
}
