import Foundation

struct MessageBubbleSenderRequest: Sendable {
    let email: String
    let personDisplayName: String?
    let personAvatarURL: String?

    /// Display name taken directly from the message's From header, when present.
    /// This is separate from Person.displayName so legacy address-derived stored
    /// names can be rejected without discarding explicit header names.
    let headerDisplayName: String?

    init(
        email: String,
        personDisplayName: String?,
        personAvatarURL: String?,
        headerDisplayName: String? = nil
    ) {
        self.email = email
        self.personDisplayName = personDisplayName
        self.personAvatarURL = personAvatarURL
        self.headerDisplayName = headerDisplayName
    }
}

struct MessageBubbleSenderResult: Sendable, Equatable {
    let name: String?
    let avatarURL: String?
    let imageData: Data?
}

struct MessageBubbleAttachmentSnapshot: Sendable, Equatable {
    let contentId: String?
    let filename: String
    let mimeType: String
    let stateRaw: String
    let localURL: String?
    let byteSize: Int64
    let pageCount: Int16
    let width: Int16
    let height: Int16

    var isReady: Bool {
        stateRaw == Attachment.State.downloaded.rawValue ||
        stateRaw == Attachment.State.uploaded.rawValue
    }
}

struct MessageBubbleHTMLAnalysis: Sendable, Equatable {
    let hasHTMLSource: Bool
    let referencedInlineContentIDs: Set<String>
    let nonDisplayableInlineContentIDs: Set<String>
    let supportsCalendarInvitePreviewCard: Bool

    static let empty = MessageBubbleHTMLAnalysis(
        hasHTMLSource: false,
        referencedInlineContentIDs: [],
        nonDisplayableInlineContentIDs: [],
        supportsCalendarInvitePreviewCard: false
    )

    static func placeholder(hasHTMLSource: Bool) -> MessageBubbleHTMLAnalysis {
        MessageBubbleHTMLAnalysis(
            hasHTMLSource: hasHTMLSource,
            referencedInlineContentIDs: [],
            nonDisplayableInlineContentIDs: [],
            supportsCalendarInvitePreviewCard: false
        )
    }
}

struct MessageBubbleContentRequest: Sendable {
    let messageID: String
    let bodyText: String?
    let chatPreviewText: String?
    let bodyStorageURI: String?
    let cleanedSnippet: String?
    let snippet: String?
    let subject: String?
    let senderName: String?
    let hasHTMLSource: Bool
    let hasAttachments: Bool
    let isFromMe: Bool
    let isForwardedEmail: Bool
    let isLikelyCalendarInvite: Bool
    let effectiveSenderEmail: String?
    let attachmentSnapshots: [MessageBubbleAttachmentSnapshot]

    init(
        messageID: String,
        bodyText: String?,
        chatPreviewText: String? = nil,
        bodyStorageURI: String?,
        cleanedSnippet: String?,
        snippet: String?,
        subject: String?,
        senderName: String?,
        hasHTMLSource: Bool,
        hasAttachments: Bool,
        isFromMe: Bool,
        isForwardedEmail: Bool,
        isLikelyCalendarInvite: Bool,
        effectiveSenderEmail: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot]
    ) {
        self.messageID = messageID
        self.bodyText = bodyText
        self.chatPreviewText = chatPreviewText
        self.bodyStorageURI = bodyStorageURI
        self.cleanedSnippet = cleanedSnippet
        self.snippet = snippet
        self.subject = subject
        self.senderName = senderName
        self.hasHTMLSource = hasHTMLSource
        self.hasAttachments = hasAttachments
        self.isFromMe = isFromMe
        self.isForwardedEmail = isForwardedEmail
        self.isLikelyCalendarInvite = isLikelyCalendarInvite
        self.effectiveSenderEmail = effectiveSenderEmail
        self.attachmentSnapshots = attachmentSnapshots
    }
}

struct MessageBubbleContentResult: Sendable, Equatable {
    let fullTextContent: String?
    let hasRichHTMLContent: Bool
    let sharedDocumentLinks: [SharedDocumentLink]
    let forwardedDisplayContent: ForwardedMessageDisplayContent?
    let htmlAnalysis: MessageBubbleHTMLAnalysis
}

struct MessageBubbleLoadContext: Sendable {
    let messageID: String
    let contentSignature: String
    let prefetchedSenderName: String?
    let senderRequest: MessageBubbleSenderRequest?
    let contentRequest: MessageBubbleContentRequest
}

protocol MessageBubbleLoading: Sendable {
    func loadSenderInfo(from request: MessageBubbleSenderRequest) async -> MessageBubbleSenderResult
    func loadContent(from request: MessageBubbleContentRequest) async -> MessageBubbleContentResult
}
