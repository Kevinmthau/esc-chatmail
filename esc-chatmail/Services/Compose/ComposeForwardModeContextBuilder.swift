import Foundation

struct ComposeForwardModeContext: Identifiable {
    let id: String
    let initialSubject: String?
    let forwardedPlainTextBody: String
    let forwardedHTMLBody: String?
    let forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo]
    let forwardedRegularAttachmentObjectURIs: [String]
}

@MainActor
struct ComposeForwardModeContextBuilder {
    let messageFormatBuilder: MessageFormatBuilder
    let outboundAttachmentContextBuilder: OutboundAttachmentContextBuilder

    func build(message: Message) throws -> ComposeForwardModeContext {
        let formattedMessage = messageFormatBuilder.formatForwardedMessage(message)

        return ComposeForwardModeContext(
            id: message.id,
            initialSubject: formattedMessage.subject,
            forwardedPlainTextBody: formattedMessage.body,
            forwardedHTMLBody: formattedMessage.htmlBody,
            forwardedInlineAttachmentInfos: try outboundAttachmentContextBuilder.buildInlineAttachmentInfos(
                from: formattedMessage.inlineAttachments
            ),
            forwardedRegularAttachmentObjectURIs: try outboundAttachmentContextBuilder.buildObjectURIs(
                from: formattedMessage.attachments
            )
        )
    }
}
