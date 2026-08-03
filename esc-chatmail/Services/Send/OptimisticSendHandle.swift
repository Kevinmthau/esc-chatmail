import CoreData
import Foundation

struct OptimisticSendHandle: Sendable, Equatable {
    let optimisticMessageID: String
    let optimisticMessageObjectID: NSManagedObjectID
    let conversationReference: ConversationReference?
}
