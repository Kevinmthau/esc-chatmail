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
    /// Factory retained for API stability. The loader is a stateless Sendable
    /// class (no longer an actor), so bubble loads never serialize through a
    /// shared executor regardless of how many rows share an instance.
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
