import Foundation

private extension ForwardedMessageDisplayContent {
    var hasForwardedHeaderFields: Bool {
        senderDisplayName != nil ||
        senderEmail != nil ||
        subject != nil ||
        timestampText != nil ||
        recipientSummary != nil
    }

    func replacingLeadInText(with leadInText: String?) -> ForwardedMessageDisplayContent {
        ForwardedMessageDisplayContent(
            leadInText: leadInText,
            senderDisplayName: senderDisplayName,
            senderEmail: senderEmail,
            subject: subject,
            timestampText: timestampText,
            recipientSummary: recipientSummary,
            previewSnippet: previewSnippet
        )
    }

    func supplementingMissingHeaderFields(
        from fallback: ForwardedMessageDisplayContent
    ) -> ForwardedMessageDisplayContent {
        ForwardedMessageDisplayContent(
            leadInText: leadInText,
            senderDisplayName: senderDisplayName ?? fallback.senderDisplayName,
            senderEmail: senderEmail ?? fallback.senderEmail,
            subject: subject ?? fallback.subject,
            timestampText: timestampText ?? fallback.timestampText,
            recipientSummary: recipientSummary ?? fallback.recipientSummary,
            previewSnippet: previewSnippet
        )
    }
}

extension MessageBubbleLoader {
    func forwardedDisplayContent(
        from request: MessageBubbleContentRequest
    ) -> ForwardedMessageDisplayContent? {
        guard request.isForwardedEmail else {
            return nil
        }

        if let chatPreviewText = nonEmptyText(request.chatPreviewText) {
            let fallbackContent = firstForwardedDisplayContent(
                from: [request.bodyText, request.cleanedSnippet, request.snippet]
            )

            guard let chatPreviewContent = ForwardedMessageDisplayParser.parseForward(from: chatPreviewText) else {
                return fallbackContent?.replacingLeadInText(with: chatPreviewText)
            }

            guard !chatPreviewContent.hasForwardedHeaderFields,
                  let fallbackContent else {
                return chatPreviewContent
            }

            return chatPreviewContent.supplementingMissingHeaderFields(from: fallbackContent)
        }

        return firstForwardedDisplayContent(
            from: [request.bodyText, request.cleanedSnippet, request.snippet]
        )
    }

    private func firstForwardedDisplayContent(
        from texts: [String?]
    ) -> ForwardedMessageDisplayContent? {
        for text in texts {
            if let content = ForwardedMessageDisplayParser.parseForward(from: text) {
                return content
            }
        }

        return nil
    }
}
