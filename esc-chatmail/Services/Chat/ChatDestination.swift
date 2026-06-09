import Foundation
import CoreData

enum ChatDestination: Identifiable {
    case emailReader(EmailReaderRoute)
    case forwardCompose(ComposeForwardModeContext)
    case addContact(ContactWrapper)
    case contactPicker
    case participants

    var id: String {
        switch self {
        case .emailReader(let route):
            return "emailReader:\(route.id)"
        case .forwardCompose(let context):
            return "forwardCompose:\(context.id)"
        case .addContact(let wrapper):
            return "addContact:\(wrapper.id.uuidString)"
        case .contactPicker:
            return "contactPicker"
        case .participants:
            return "participants"
        }
    }
}

struct EmailReaderRoute: Hashable, Identifiable {
    let messageObjectID: NSManagedObjectID
    let conversationObjectID: NSManagedObjectID?
    let source: EmailReaderOpenSource
    let initialMode: EmailReaderMode

    var id: String {
        [
            messageObjectID.uriRepresentation().absoluteString,
            conversationObjectID?.uriRepresentation().absoluteString ?? "conversation:nil",
            source.rawValue,
            initialMode.rawValue
        ].joined(separator: "|")
    }
}

enum EmailReaderMode: String, Hashable {
    case original
}

enum EmailReaderOpenSource: String, Hashable {
    case bubbleAccessory
    case contextMenu
    case previewCard
    case debugOrFallback
}
