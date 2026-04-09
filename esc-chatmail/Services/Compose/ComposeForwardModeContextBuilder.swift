import Foundation

struct ComposeForwardModeContext: Identifiable {
    let id: String
    let initialSubject: String?
    let forwardedPlainTextBody: String
    let forwardedHTMLBody: String?
    let forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo]
    let forwardedRegularAttachments: [ForwardAttachmentSnapshot]
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

        return ComposeForwardModeContext(
            id: input.source.id,
            initialSubject: formattedMessage.subject,
            forwardedPlainTextBody: formattedMessage.body,
            forwardedHTMLBody: formattedMessage.htmlBody,
            forwardedInlineAttachmentInfos: input.forwardedInlineAttachmentInfos,
            forwardedRegularAttachments: input.forwardedRegularAttachments
        )
    }
}
