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
    /// Use a factory so visible bubbles do not serialize through one shared actor.
    let makeMessageBubbleLoader: () -> MessageBubbleLoader
    let viewContext: NSManagedObjectContext
    let makeBackgroundContext: () -> NSManagedObjectContext
    let makeChatContactManager: @MainActor () -> ChatContactManager
    let invalidateContactsCache: () async -> Void
    let clearPersonCache: () async -> Void
}
