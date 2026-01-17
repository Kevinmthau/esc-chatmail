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
    @State private var hasLoadedContent = false

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
        if !message.isFromMe && style.showSenderName && isGroupConversation && senderName != nil {
            Text(senderName!)
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
        let displayable = message.displayableAttachments
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
        guard !hasLoadedContent else { return }
        hasLoadedContent = true

        // Use prefetched sender name if available, otherwise load (needed for avatar)
        if !message.isFromMe {
            if let prefetched = prefetchedSenderName {
                senderName = prefetched
            }
            // Always load to get avatar URL (and sender name if not prefetched)
            await loadSenderName()
        }

        // Try cache first (populated by batch prefetch in ChatView.onAppear)
        if let cached = await ProcessedTextCache.shared.get(messageId: message.id) {
            fullTextContent = cached.plainText
            hasRichContent = message.isForwardedEmail || (!message.isFromMe && cached.hasRichContent)
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

        let result: (plainText: String?, hasRichContent: Bool) = await Task.detached(priority: .userInitiated) {
            let handler = HTMLContentHandler.shared
            var processedResult = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

            // If no HTML content, try bodyText
            if processedResult.plainText == nil, let text = bodyText {
                let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: text)
                processedResult = (TextProcessing.stripQuotedText(from: unwrapped), false)
            }

            // Cache the result for future use
            await ProcessedTextCache.shared.set(
                messageId: messageId,
                plainText: processedResult.plainText,
                hasRichContent: processedResult.hasRichContent
            )

            return processedResult
        }.value

        fullTextContent = result.plainText
        hasRichContent = isForwarded || (!isFromMe && result.hasRichContent)
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
