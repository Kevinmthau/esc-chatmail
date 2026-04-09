import Foundation

struct OptimisticSendHandle: Sendable, Equatable {
    let optimisticMessageID: String
    let conversationObjectURI: String?
}
