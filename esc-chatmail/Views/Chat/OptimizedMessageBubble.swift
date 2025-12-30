import SwiftUI

// MARK: - Optimized Message Bubble
struct OptimizedMessageBubble: View {
    let message: Message
    let conversation: Conversation
    @State private var isExpanded = false
    @State private var htmlLoaded = false

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
            // Sender info
            if !message.isFromMe {
                Text(message.senderNameValue ?? "Unknown")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Message content
            messageContent
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .cornerRadius(16)

            // Timestamp
            Text(message.internalDate.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageContent: some View {
        if let snippet = message.cleanedSnippet ?? message.snippet {
            Text(snippet)
                .foregroundColor(message.isFromMe ? .white : .primary)
                .lineLimit(isExpanded ? nil : 3)
                .onTapGesture {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }
        }

        if message.hasAttachments {
            let attachmentCount = message.typedAttachments.count
            AttachmentIndicator(count: attachmentCount)
        }
    }

    private var bubbleBackground: some View {
        Group {
            if message.isFromMe {
                Color.blue
            } else {
                Color(.systemGray5)
            }
        }
    }
}
