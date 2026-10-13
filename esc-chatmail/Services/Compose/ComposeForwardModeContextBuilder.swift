import Foundation

struct ComposeForwardModeContext: Identifiable {
    let id: String
    let initialSubject: String?
    let forwardedPlainTextBody: String
    let forwardedHTMLBody: String?
    let forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo]
    let forwardedRegularAttachments: [ForwardAttachmentSnapshot]
    let initialRecipientEmails: [String]
    let initialBody: String
    let recoveredAttachmentReferences: [LocalAttachmentReference]
    let recoveredMessageID: String?

    init(
        id: String,
        initialSubject: String?,
        forwardedPlainTextBody: String,
        forwardedHTMLBody: String?,
        forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo],
        forwardedRegularAttachments: [ForwardAttachmentSnapshot],
        initialRecipientEmails: [String] = [],
        initialBody: String = "",
        recoveredAttachmentReferences: [LocalAttachmentReference] = [],
        recoveredMessageID: String? = nil
    ) {
        self.id = id
        self.initialSubject = initialSubject
        self.forwardedPlainTextBody = forwardedPlainTextBody
        self.forwardedHTMLBody = forwardedHTMLBody
        self.forwardedInlineAttachmentInfos = forwardedInlineAttachmentInfos
        self.forwardedRegularAttachments = forwardedRegularAttachments
        self.initialRecipientEmails = initialRecipientEmails
        self.initialBody = initialBody
        self.recoveredAttachmentReferences = recoveredAttachmentReferences
        self.recoveredMessageID = recoveredMessageID
    }
}

@MainActor
struct ComposeForwardModeContextBuilder {
    let messageFormatBuilder: MessageFormatBuilder

    struct Input {
        let source: MessageFormatBuilder.ForwardSource
        let forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let forwardedRegularAttachments: [ForwardAttachmentSnapshot]
    }

    func build(input: Input) -> ComposeForwardModeContext {
        let formattedMessage = messageFormatBuilder.formatForwardedMessage(input.source)
        let canPreserveRichInlineContent = input.forwardedInlineAttachmentInfos.allSatisfy { info in
            guard let contentId = info.contentId else { return false }
            return MimeBuilder.canEmitContentIdVerbatim(contentId)
        }

        return ComposeForwardModeContext(
            id: input.source.id,
            initialSubject: formattedMessage.subject,
            forwardedPlainTextBody: formattedMessage.body,
            forwardedHTMLBody: canPreserveRichInlineContent ? formattedMessage.htmlBody : nil,
            forwardedInlineAttachmentInfos: canPreserveRichInlineContent
                ? input.forwardedInlineAttachmentInfos
                : [],
            forwardedRegularAttachments: input.forwardedRegularAttachments
        )
    }
}
