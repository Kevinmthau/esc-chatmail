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
    @State private var hasRichContent = false
    @State private var fullTextContent: String?
    @State private var quotedParts: [QuotedPart] = []
    @State private var hasLoadedContent = false
    /// Tracks the message ID we're currently loading to prevent stale updates during cell reuse
    @State private var loadingMessageId: String?

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
                    hasRichContent: hasRichContent,
                    fullTextContent: fullTextContent,
                    showingHTMLView: $showingHTMLView
                )

                // Show collapsible quotes if available (only for text bubbles, not newsletters)
                if !message.isNewsletter && !hasRichContent && !quotedParts.isEmpty {
                    CollapsibleQuoteView(quotedParts: quotedParts, isFromMe: message.isFromMe)
                }

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
        .task {
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
        }
    }

    @ViewBuilder
    private var attachmentsView: some View {
        // Filter out inline attachments when HTML is rendered (they're shown via cid: URLs)
        let showsHTML = message.isNewsletter || hasRichContent
        let displayable = message.displayableAttachments.filter { attachment in
            // Inline attachments (with contentId) are shown in HTML content, so exclude them
            if showsHTML && attachment.contentId != nil {
                return false
            }
            return true
        }
        #if DEBUG
        let _ = {
            if message.hasAttachments {
                let attachmentDetails = message.attachmentsArray.map { "[\($0.filename), cid:\($0.contentId ?? "nil")]" }.joined(separator: ", ")
                Log.warning("UI_DEBUG msg=\(message.id) hasAttachments=\(message.hasAttachments) attachmentsArray=\(message.attachmentsArray.count) displayable=\(displayable.count) showsHTML=\(showsHTML) hasRichContent=\(hasRichContent) attachments=\(attachmentDetails)", category: .ui)
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
    }

    // MARK: - Helpers

    private var isGroupConversation: Bool {
        conversation.conversationType == .group || conversation.conversationType == .list
    }

    // MARK: - Content Loading

    private func loadContentIfNeeded() async {
        let currentMessageId = message.id

        // Early exit: content already loaded for this exact message
        if hasLoadedContent && loadingMessageId == currentMessageId {
            return
        }

        // Claim this message ID and reset all state for new load
        // This ensures a clean slate when cell is reused for a different message
        loadingMessageId = currentMessageId
        hasLoadedContent = false
        fullTextContent = nil
        hasRichContent = false
        quotedParts = []

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
            hasRichContent = message.isForwardedEmail || (!message.isFromMe && cached.hasRichContent)
            quotedParts = cached.quotedParts
            hasLoadedContent = true
        } else {
            // Fallback: process on background thread and cache result
            await loadFullTextContentWithCache()
        }
    }

    private func loadFullTextContentWithCache() async {
        let messageId = message.id
        let bodyText = message.bodyTextValue
        let isFromMe = message.isFromMe
        let isForwarded = message.isForwardedEmail

        let result: (plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart]) = await Task.detached(priority: .userInitiated) {
            let handler = HTMLContentHandler.shared
            var processedResult = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

            // If no HTML content, try bodyText
            if processedResult.plainText == nil, let text = bodyText {
                let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: text)
                let extractionResult = PlainTextQuoteRemover.extractQuotes(from: unwrapped)
                // Only use if we actually have content after stripping
                processedResult = (
                    extractionResult.mainContent.isEmpty ? nil : extractionResult.mainContent,
                    false,
                    extractionResult.quotedParts
                )
            }

            // Cache the result for future use
            await ProcessedTextCache.shared.set(
                messageId: messageId,
                plainText: processedResult.plainText,
                hasRichContent: processedResult.hasRichContent,
                quotedParts: processedResult.quotedParts
            )

            return processedResult
        }.value

        // Verify message ID hasn't changed during async processing (cell reuse protection)
        guard loadingMessageId == messageId else { return }

        fullTextContent = result.plainText
        hasRichContent = isForwarded || (!isFromMe && result.hasRichContent)
        quotedParts = result.quotedParts
        hasLoadedContent = true
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
