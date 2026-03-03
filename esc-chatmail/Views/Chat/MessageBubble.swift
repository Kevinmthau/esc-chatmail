import SwiftUI

struct MessageBubble: View {
    let message: Message
    let conversation: Conversation
    /// Pre-loaded sender names from batch fetch (avoids N+1 queries)
    var prefetchedSenderName: String?
    /// Whether this is the last message from this sender before a different sender (for avatar grouping)
    var isLastFromSender: Bool = true
    /// Display style configuration
    var style: MessageBubbleStyle = .standard

    private let contactsResolver = ContactsResolver.shared
    @State private var senderName: String?
    @State private var senderAvatarURL: String?
    @State private var senderImageData: Data?
    @State private var showingHTMLView = false
    @State private var hasRichHTMLContent = false
    private var showHTMLPreview: Bool {
        MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: message.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isNewsletter: message.isNewsletter,
            hasRichHTMLContent: hasRichHTMLContent,
            isFromMe: message.isFromMe,
            isOneToOneConversation: conversation.conversationType == .oneToOne,
            subject: message.subject,
            senderEmail: effectiveSenderEmail
        )
    }
    @State private var fullTextContent: String?
    @State private var hasLoadedContent = false
    @State private var lastContentSignature: String?
    @State private var sharedDocumentLinks: [SharedDocumentLink] = []
    /// Tracks the message ID we're currently loading to prevent stale updates during cell reuse
    @State private var loadingMessageId: String?

    init(
        message: Message,
        conversation: Conversation,
        prefetchedSenderName: String? = nil,
        isLastFromSender: Bool = true,
        style: MessageBubbleStyle = .standard
    ) {
        self.message = message
        self.conversation = conversation
        self.prefetchedSenderName = prefetchedSenderName
        self.isLastFromSender = isLastFromSender
        self.style = style

        // No stateful HTML preview flag needed; derived from message metadata.
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !message.isFromMe {
                leadingContent
            } else {
                Spacer()
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                senderNameView

                subjectView

                attachmentsView

                MessageContentView(
                    message: message,
                    style: style,
                    showHTMLPreview: showHTMLPreview,
                    fullTextContent: fullTextContent,
                    hasLoadedContent: hasLoadedContent,
                    showingHTMLView: $showingHTMLView
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    showingHTMLView = true
                }

                sendStatusView

                MessageMetadata(
                    date: message.internalDate,
                    isUnread: message.isUnread,
                    showUnreadIndicator: style.showUnreadIndicator
                )
            }
            .frame(maxWidth: style.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)

            if !message.isFromMe {
                Spacer()
            }
        }
        .task(id: contentSignature()) {
            await loadContentIfNeeded()
        }
        .sheet(isPresented: $showingHTMLView) {
            HTMLMessageView(message: message)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var leadingContent: some View {
        if style.showAvatar {
            if isLastFromSender {
                BubbleAvatarView(name: senderName ?? "?", avatarURL: senderAvatarURL, imageData: senderImageData)
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
    }

    @ViewBuilder
    private var senderNameView: some View {
        if !message.isFromMe && style.showSenderName && isGroupConversation, let name = senderName {
            Text(name)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var subjectView: some View {
        if let subject = message.subject, !subject.isEmpty {
            Text(subject)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundColor(message.isFromMe ? .secondary : .primary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var sendStatusView: some View {
        if message.isSendingLocalAttachments {
            MessageSendingIndicator()
        } else if message.hasFailedLocalAttachmentUploads {
            Text("Send failed")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var attachmentsView: some View {
        let displayable = message.displayableAttachments(hidingInlineReferencedInHTML: showHTMLPreview)
        #if DEBUG
        let _ = {
            if message.hasAttachments {
                let attachmentDetails = message.attachmentsArray.map { "[\($0.filename), cid:\($0.contentId ?? "nil")]" }.joined(separator: ", ")
                Log.warning("UI_DEBUG msg=\(message.id) hasAttachments=\(message.hasAttachments) attachmentsArray=\(message.attachmentsArray.count) displayable=\(displayable.count) showHTMLPreview=\(showHTMLPreview) attachments=\(attachmentDetails)", category: .ui)
            }
        }()
        #endif
        if !displayable.isEmpty {
            if style.showAttachmentGrid {
                AttachmentGridView(attachments: displayable)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.65)
            } else {
                AttachmentIndicator(count: displayable.count)
            }
        }

        if !sharedDocumentLinks.isEmpty {
            VStack(spacing: 8) {
                ForEach(sharedDocumentLinks) { link in
                    SharedDocumentLinkCard(link: link)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.65)
        }
    }

    // MARK: - Helpers

    private var isGroupConversation: Bool {
        conversation.conversationType == .group || conversation.conversationType == .list
    }

    private var effectiveSenderEmail: String? {
        if let senderEmail = message.senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !senderEmail.isEmpty {
            return senderEmail
        }

        return message.participants?
            .first(where: { $0.participantKind == .from })?
            .person?
            .email
    }

    // MARK: - Content Loading

    private func loadContentIfNeeded() async {
        let currentMessageId = message.id
        let signature = contentSignature()

        // Early exit: content already loaded for this exact message
        if hasLoadedContent && loadingMessageId == currentMessageId && lastContentSignature == signature {
            return
        }

        // Claim this message ID and reset state for new load
        // This ensures a clean slate when cell is reused for a different message
        loadingMessageId = currentMessageId
        hasLoadedContent = false
        fullTextContent = nil
        hasRichHTMLContent = false
        lastContentSignature = signature
        refreshSharedDocumentLinks(using: nil)

        // Use prefetched sender name if available, otherwise load (needed for avatar)
        if !message.isFromMe {
            if let prefetched = prefetchedSenderName {
                senderName = prefetched
            }
            // Always load to get avatar URL (and sender name if not prefetched)
            await loadSenderName()
        }

        // Verify message ID hasn't changed during async work (cell reuse protection)
        guard loadingMessageId == currentMessageId else { return }

        // Try cache first (populated by batch prefetch in ChatView.onAppear)
        if let cached = await ProcessedTextCache.shared.get(messageId: message.id) {
            // Final check before updating state - ensure this is still the active message
            guard loadingMessageId == currentMessageId else { return }
            fullTextContent = cached.plainText
            hasRichHTMLContent = cached.hasRichContent
            refreshSharedDocumentLinks(using: cached.plainText)

            let hasHTMLFile = HTMLContentHandler.shared.htmlFileExists(for: message.id)
            let hasHTMLSource = message.hasHTMLSource

            // Prefetch may have cached a result without considering bodyStorageURI.
            // If we have an HTML source but the cache lacks plain text and the file isn't
            // in the messageId location, recompute using the URI for correctness.
            if hasHTMLSource && cached.plainText == nil && message.bodyStorageURI != nil && !hasHTMLFile {
                await loadFullTextContentWithCache()
                return
            }

            hasLoadedContent = true
        } else {
            // Fallback: process on background thread and cache result
            await loadFullTextContentWithCache()
        }
    }

    private func contentSignature() -> String {
        let bodyTextHash = message.bodyText?.hashValue ?? 0
        let snippetHash = message.snippet?.hashValue ?? 0
        return "\(message.bodyStorageURI ?? "")|\(bodyTextHash)|\(snippetHash)|\(message.hasHTMLSource)"
    }

    private func loadFullTextContentWithCache() async {
        let messageId = message.id
        let bodyText = message.bodyTextValue
        let bodyStorageURI = message.bodyStorageURI
        let initialResult: (plainText: String?, hasRichContent: Bool) = await Task.detached(priority: .userInitiated) {
            let handler = HTMLContentHandler.shared
            var processedResult = ProcessedTextCache.processMessage(
                messageId: messageId,
                bodyStorageURI: bodyStorageURI,
                handler: handler
            )

            // If no HTML content, try bodyText
            if processedResult.plainText == nil, let text = bodyText {
                let fallbackResult = ChatBubbleTextProcessor.process(
                    content: text,
                    options: ChatBubbleTextProcessorOptions(
                        // Some providers leak HTML markup into text/plain fallbacks.
                        // Auto-detect so rich transactional templates can still route to preview mode.
                        inputKind: .autoDetectHTML,
                        sanitizeRawEmailSource: true,
                        decodeHTMLEntities: true,
                        formatSignOffLineBreaks: true,
                        classifyRichContent: true
                    )
                )
                processedResult = (
                    fallbackResult.mainText,
                    fallbackResult.hasRichContent,
                    fallbackResult.quotedParts
                )
            }

            // Cache the result for future use
            await ProcessedTextCache.shared.set(
                messageId: messageId,
                plainText: processedResult.plainText,
                hasRichContent: processedResult.hasRichContent,
                quotedParts: processedResult.quotedParts
            )

            return (processedResult.plainText, processedResult.hasRichContent)
        }.value

        var result = initialResult

        let missingBodyText = bodyText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let isTrustedTransactionalSender = MessageDisplayPolicy.isTrustedTransactionalSender(effectiveSenderEmail)
        let shouldAttemptHTMLRecovery =
            result.plainText == nil &&
            missingBodyText &&
            !message.isFromMe &&
            (message.bodyStorageURI != nil || message.hasAttachments || message.hasHTMLSource)
        let shouldAttemptTrustedSenderRecovery =
            !message.isFromMe &&
            !message.hasHTMLSource &&
            !result.hasRichContent &&
            isTrustedTransactionalSender

        if (shouldAttemptHTMLRecovery || shouldAttemptTrustedSenderRecovery),
           let recoveredHTML = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId) {
            let recoveredResult: (plainText: String?, hasRichContent: Bool) = await Task.detached(priority: .userInitiated) {
                let processed = ChatBubbleTextProcessor.process(
                    content: recoveredHTML,
                    options: ChatBubbleTextProcessorOptions(
                        inputKind: .html,
                        sanitizeRawEmailSource: false,
                        decodeHTMLEntities: true,
                        formatSignOffLineBreaks: true,
                        classifyRichContent: true
                    )
                )

                await ProcessedTextCache.shared.set(
                    messageId: messageId,
                    plainText: processed.mainText,
                    hasRichContent: processed.hasRichContent,
                    quotedParts: processed.quotedParts
                )

                return (processed.mainText, processed.hasRichContent)
            }.value

            if recoveredResult.plainText != nil || recoveredResult.hasRichContent {
                result = recoveredResult
            }
        }

        // Verify message ID hasn't changed during async processing (cell reuse protection)
        guard loadingMessageId == messageId else { return }

        fullTextContent = result.plainText
        hasRichHTMLContent = result.hasRichContent
        refreshSharedDocumentLinks(using: result.plainText)
        hasLoadedContent = true
    }

    private func refreshSharedDocumentLinks(using preferredText: String?) {
        let candidates = [preferredText, message.bodyText, message.snippet]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        sharedDocumentLinks = SharedDocumentLinkExtractor.extract(from: candidates, maxCount: 4)
    }

    private func loadSenderName() async {
        guard let participants = message.participants else { return }

        for participant in participants {
            if participant.participantKind == .from,
               let person = participant.person {
                let email = person.email

                // Load avatar URL from Person entity
                senderAvatarURL = person.avatarURL

                // Look up contact in address book for name and photo
                let match = await contactsResolver.lookup(email: email)

                // Use contact image data if available
                if let imageData = match?.imageData {
                    senderImageData = imageData
                }

                if let personName = person.displayName, !personName.isEmpty {
                    senderName = personName
                    return
                }

                if let displayName = match?.displayName {
                    senderName = displayName
                } else {
                    senderName = EmailNormalizer.formatAsDisplayName(email: email)
                }
                return
            }
        }
    }
}
