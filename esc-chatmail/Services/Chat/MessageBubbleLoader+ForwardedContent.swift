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
                return fallbackContent?.replacingLeadInText(
                    with: leadInTextForUnparsedChatPreview(chatPreviewText, request: request)
                )
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

    private func leadInTextForUnparsedChatPreview(
        _ chatPreviewText: String,
        request: MessageBubbleContentRequest
    ) -> String? {
        guard request.isFromMe else {
            return chatPreviewText
        }

        return isForwardedBodyEcho(
            chatPreviewText,
            in: [request.bodyText, request.cleanedSnippet, request.snippet]
        ) ? nil : chatPreviewText
    }

    private func isForwardedBodyEcho(
        _ text: String,
        in candidates: [String?]
    ) -> Bool {
        guard let normalizedText = comparableForwardText(text),
              normalizedText.count >= 24,
              normalizedText.split(separator: " ").count >= 4 else {
            return false
        }

        return candidates.contains { candidate in
            guard let forwardedBlock = forwardedBlock(afterMarkerIn: candidate),
                  let normalizedBlock = comparableForwardText(forwardedBlock) else {
                return false
            }

            return normalizedBlock.contains(normalizedText)
        }
    }

    private func forwardedBlock(afterMarkerIn text: String?) -> String? {
        guard let text, !text.isEmpty,
              let markerPattern = Self.forwardMarkerPattern else {
            return nil
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let match = markerPattern.firstMatch(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        ),
              let range = Range(match.range, in: normalized) else {
            return nil
        }

        return String(normalized[range.upperBound...])
    }

    private func comparableForwardText(_ text: String) -> String? {
        let normalized = HTMLEntityDecoder.decode(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        return normalized.isEmpty ? nil : normalized
    }

    private static let forwardMarkerPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?i)(?:Begin forwarded message:|-{2,}[ \t]*Forwarded message\b(?:[ \t]*-{2,})?)"#,
            options: []
        )
    }()

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
