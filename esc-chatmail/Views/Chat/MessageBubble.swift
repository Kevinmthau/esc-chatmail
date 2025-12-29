import SwiftUI

struct MessageBubble: View {
    let message: Message
    let conversation: Conversation
    /// Pre-loaded sender names from batch fetch (avoids N+1 queries)
    var prefetchedSenderName: String?

    private let contactsResolver = ContactsResolver.shared
    @State private var senderName: String?
    @State private var showingHTMLView = false
    @State private var hasRichContent = false
    @State private var fullTextContent: String?
    @State private var hasLoadedContent = false

    private var htmlContentHandler: HTMLContentHandler { HTMLContentHandler.shared }

    var body: some View {
        HStack {
            if message.isFromMe {
                Spacer()
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if !message.isFromMe && isGroupConversation && senderName != nil {
                    Text(senderName!)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }

                if let subject = message.subject, !subject.isEmpty {
                    Text(subject)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(message.isFromMe ? .secondary : .primary)
                }

                if !message.typedAttachments.isEmpty {
                    AttachmentGridView(attachments: message.attachmentsArray)
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.65)
                }

                if message.isNewsletter {
                    VStack(alignment: .leading, spacing: 8) {
                        if let text = fullTextContent ?? message.cleanedSnippet ?? message.snippet, !text.isEmpty {
                            Text(text)
                                .lineLimit(4)
                                .padding(10)
                                .background(Color.gray.opacity(0.2))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                                .frame(maxWidth: 260)
                        }

                        Button(action: {
                            showingHTMLView = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.richtext")
                                    .font(.caption)
                                Text("View Full Email")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption2)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                } else {
                    if let text = fullTextContent ?? message.cleanedSnippet ?? message.snippet, !text.isEmpty {
                        // Show "View More" if text has many lines OR is very long (long paragraphs)
                        let lineCount = text.components(separatedBy: .newlines).count
                        let isTruncated = lineCount > 15 || text.count > 800
                        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
                            Text(text)
                                .lineLimit(15)
                                .padding(10)
                                .background(message.isFromMe ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(message.isFromMe ? .white : .primary)
                                .cornerRadius(12)

                            if hasRichContent || isTruncated {
                                Button(action: {
                                    showingHTMLView = true
                                }) {
                                    HStack(spacing: 4) {
                                        Text("View More")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Image(systemName: "arrow.up.forward")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    } else if message.bodyStorageURI != nil || htmlContentHandler.htmlFileExists(for: message.id) {
                        // No text content but HTML exists - show button to view it
                        Button(action: {
                            showingHTMLView = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.richtext")
                                    .font(.caption)
                                Text("View Email")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption2)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }
                    } else {
                        // No content available at all - show minimal placeholder
                        Text("No preview available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(10)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)
                    }
                }

                HStack(spacing: 8) {
                    if message.isUnread {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }

                    Text(formatTime(message.internalDate))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 280, alignment: message.isFromMe ? .trailing : .leading)

            if !message.isFromMe {
                Spacer()
            }
        }
        .task {
            guard !hasLoadedContent else { return }
            hasLoadedContent = true

            // Use prefetched sender name if available, otherwise load
            if !message.isFromMe && isGroupConversation {
                if let prefetched = prefetchedSenderName {
                    senderName = prefetched
                } else {
                    await loadSenderName()
                }
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
        .sheet(isPresented: $showingHTMLView) {
            HTMLMessageView(message: message)
        }
    }

    private var isGroupConversation: Bool {
        conversation.conversationType == .group || conversation.conversationType == .list
    }

    /// Loads and caches text content on background thread
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
                processedResult = (TextProcessing.stripQuotedText(from: text), false)
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

                if let personName = person.displayName, !personName.isEmpty {
                    senderName = personName
                    return
                }

                if let match = await contactsResolver.lookup(email: email),
                   let displayName = match.displayName {
                    senderName = displayName
                } else {
                    let normalized = EmailNormalizer.normalize(email)
                    if let atIndex = normalized.firstIndex(of: "@") {
                        senderName = String(normalized[..<atIndex])
                    } else {
                        senderName = email
                    }
                }
                return
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}
