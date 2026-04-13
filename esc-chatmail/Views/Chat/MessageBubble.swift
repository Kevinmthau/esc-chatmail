import SwiftUI
import CryptoKit

struct MessageBubble: View {
    let message: Message
    let conversation: Conversation
    /// Pre-loaded sender names from batch fetch (avoids N+1 queries)
    var prefetchedSenderName: String?
    /// Optional presentation override for threads that collapse multiple emails into one contact.
    var isEffectivelyOneToOneConversation: Bool?
    /// Bumps when local contact data changes so sender labels/avatars reload in-place.
    var contactRefreshToken: Int = 0
    /// Whether this is the last message from this sender before a different sender (for avatar grouping)
    var isLastFromSender: Bool = true
    /// Display style configuration
    var style: MessageBubbleStyle = .standard

    @StateObject private var viewModel: MessageBubbleViewModel
    let onOpenFullMessage: (Message) -> Void

    private var showHTMLPreview: Bool {
        MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: message.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isNewsletter: message.isNewsletter,
            hasRichHTMLContent: viewModel.hasRichHTMLContent,
            isFromMe: message.isFromMe,
            isOneToOneConversation: effectiveIsOneToOneConversation,
            subject: message.subject,
            senderEmail: effectiveSenderEmail
        )
    }

    private var outgoingForwardedDisplayContent: ForwardedMessageDisplayContent? {
        viewModel.forwardedDisplayContent ?? message.outgoingForwardedDisplayContent
    }

    @MainActor
    init(
        message: Message,
        conversation: Conversation,
        deps: Dependencies? = nil,
        prefetchedSenderName: String? = nil,
        isEffectivelyOneToOneConversation: Bool? = nil,
        contactRefreshToken: Int = 0,
        isLastFromSender: Bool = true,
        style: MessageBubbleStyle = .standard,
        onOpenFullMessage: @escaping (Message) -> Void
    ) {
        let resolvedDeps = deps ?? Dependencies.shared
        self.message = message
        self.conversation = conversation
        self.prefetchedSenderName = prefetchedSenderName
        self.isEffectivelyOneToOneConversation = isEffectivelyOneToOneConversation
        self.contactRefreshToken = contactRefreshToken
        self.isLastFromSender = isLastFromSender
        self.style = style
        self.onOpenFullMessage = onOpenFullMessage
        self._viewModel = StateObject(wrappedValue: MessageBubbleViewModel(deps: resolvedDeps))
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
                    fullTextContent: viewModel.fullTextContent,
                    hasLoadedContent: viewModel.hasLoadedContent,
                    forwardedDisplayContent: outgoingForwardedDisplayContent,
                    onOpenFullMessage: openFullMessage
                )

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
        .task(id: loadSignature) {
            await viewModel.loadIfNeeded(using: loadContext)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var leadingContent: some View {
        if style.showAvatar {
            if isLastFromSender {
                BubbleAvatarView(
                    name: viewModel.senderName ?? "?",
                    avatarURL: viewModel.senderAvatarURL,
                    imageData: viewModel.senderImageData
                )
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
    }

    @ViewBuilder
    private var senderNameView: some View {
        if !message.isFromMe && style.showSenderName && isGroupConversation, let name = viewModel.senderName {
            Text(name)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var subjectView: some View {
        if outgoingForwardedDisplayContent == nil,
           !(showHTMLPreview && message.isNewsletter),
           let subject = message.subject, !subject.isEmpty {
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
                    .frame(maxWidth: style.maxBubbleWidth)
            } else {
                AttachmentIndicator(count: displayable.count)
            }
        }

        if !viewModel.sharedDocumentLinks.isEmpty {
            VStack(spacing: 8) {
                ForEach(viewModel.sharedDocumentLinks) { link in
                    SharedDocumentLinkCard(link: link)
                }
            }
            .frame(maxWidth: style.maxBubbleWidth)
        }
    }

    // MARK: - Helpers

    private var isGroupConversation: Bool {
        !effectiveIsOneToOneConversation
    }

    private var effectiveIsOneToOneConversation: Bool {
        isEffectivelyOneToOneConversation ?? (conversation.conversationType == .oneToOne)
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

    private var senderRequest: MessageBubbleSenderRequest? {
        guard !message.isFromMe,
              let senderParticipant = message.participants?
                .first(where: { $0.participantKind == .from }),
              let person = senderParticipant.person else {
            return nil
        }

        return MessageBubbleSenderRequest(
            email: person.email,
            personDisplayName: person.displayName,
            personAvatarURL: person.avatarURL
        )
    }

    private var loadContext: MessageBubbleLoadContext {
        MessageBubbleLoadContext(
            messageID: message.id,
            contentSignature: loadSignature,
            prefetchedSenderName: prefetchedSenderName,
            senderRequest: senderRequest,
            contentRequest: MessageBubbleContentRequest(
                messageID: message.id,
                bodyText: message.bodyTextValue,
                bodyStorageURI: message.bodyStorageURI,
                snippet: message.snippet,
                hasHTMLSource: message.hasHTMLSource,
                hasAttachments: message.hasAttachments,
                isFromMe: message.isFromMe,
                isForwardedEmail: message.isForwardedEmail,
                effectiveSenderEmail: effectiveSenderEmail
            )
        )
    }

    private var loadSignature: String {
        Self.contentSignature(
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyTextValue,
            snippet: message.snippet,
            hasHTMLSource: message.hasHTMLSource,
            contactRefreshToken: contactRefreshToken
        )
    }

    private func openFullMessage() {
        onOpenFullMessage(message)
    }

    static func contentSignature(
        bodyStorageURI: String?,
        bodyText: String?,
        snippet: String?,
        hasHTMLSource: Bool,
        contactRefreshToken: Int
    ) -> String {
        "\(bodyStorageURI ?? "")|\(contentFingerprint(for: bodyText))|\(contentFingerprint(for: snippet))|\(hasHTMLSource)|contacts:\(contactRefreshToken)"
    }

    private static func contentFingerprint(for text: String?) -> String {
        guard let text else { return "nil" }
        return SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
