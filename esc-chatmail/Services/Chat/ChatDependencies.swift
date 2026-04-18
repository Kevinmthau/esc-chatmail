import Foundation
import CoreData

struct ChatDependencies {
    let authSession: AuthSession
    let participantLoader: ParticipantLoader
    let htmlContentHandler: HTMLContentHandler
    let processedTextCache: ProcessedTextCache
    let contactsResolver: any ContactsResolving
    let messageActions: MessageActions
    let outboundMessageCoordinator: any OutboundMessageCoordinating
    let outboundAttachmentContextBuilder: OutboundAttachmentContextBuilder
    let outboundReplyContextBuilder: OutboundReplyContextBuilder
    let composeForwardModeContextBuilder: ComposeForwardModeContextBuilder
    let messageBubbleLoader: any MessageBubbleLoading
    let viewContext: NSManagedObjectContext
    let makeBackgroundContext: () -> NSManagedObjectContext
    let makeChatContactManager: @MainActor () -> ChatContactManager
    let invalidateContactsCache: () async -> Void
    let clearPersonCache: () async -> Void
}
