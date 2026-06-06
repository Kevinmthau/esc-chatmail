import Foundation
import CoreData

struct ChatDependencies {
    let session: ChatSessionDependencies
    let content: ChatContentDependencies
    let messaging: ChatMessagingDependencies
    let contacts: ChatContactDependencies
    let storage: ChatStorageDependencies
    let fullEmailOpener: any FullEmailOpening
}

struct ChatSessionDependencies {
    let authSession: AuthSession
}

struct ChatContentDependencies {
    let htmlContentHandler: HTMLContentHandler
    let processedTextCache: ProcessedTextCache
    let originalEmailSourceWarmer: any OriginalEmailSourceWarming
    /// Use a factory so visible bubbles do not serialize through one shared actor.
    let makeMessageBubbleLoader: () -> MessageBubbleLoader
}

struct ChatMessagingDependencies {
    let messageActions: MessageActions
    let outboundMessageCoordinator: any OutboundMessageCoordinating
    let outboundAttachmentContextBuilder: OutboundAttachmentContextBuilder
    let outboundReplyContextBuilder: OutboundReplyContextBuilder
    let composeForwardModeContextBuilder: ComposeForwardModeContextBuilder
}

struct ChatContactDependencies {
    let participantLoader: ParticipantLoader
    let contactsResolver: any ContactsResolving
    let makeChatContactManager: @MainActor () -> ChatContactManager
    let invalidateContactsCache: () async -> Void
    let clearPersonCache: () async -> Void
}

struct ChatStorageDependencies {
    let viewContext: NSManagedObjectContext
    let makeBackgroundContext: () -> NSManagedObjectContext
}
