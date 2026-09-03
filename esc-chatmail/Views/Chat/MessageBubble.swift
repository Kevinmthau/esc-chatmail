import SwiftUI
import CoreData

enum MessageSendStatusPresentation: Equatable {
    case none
    case sending
    case notSent
    case deliveryUnknown
    case sendFailed

    var label: String? {
        switch self {
        case .notSent:
            return "Not sent"
        case .deliveryUnknown:
            return "Delivery unknown"
        case .sendFailed:
            return "Send failed"
        case .none, .sending:
            return nil
        }
    }

    static func resolve(
        deliveryState: OutboundSendDeliveryState,
        isSendingLocalAttachments: Bool,
        hasFailedLocalAttachmentUploads: Bool
    ) -> Self {
        switch deliveryState {
        case .sending:
            return .sending
        case .notSent:
            return .notSent
        case .deliveryUnknown:
            return .deliveryUnknown
        case .none:
            if isSendingLocalAttachments { return .sending }
            if hasFailedLocalAttachmentUploads { return .sendFailed }
            return .none
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessageRowModel
    /// Pre-loaded sender names from batch fetch (avoids N+1 queries)
    var prefetchedSenderName: String?
    /// Presentation mode for threads that collapse multiple emails into one contact.
    var isEffectivelyOneToOneConversation: Bool
    /// Bumps when local contact data changes so sender labels/avatars reload in-place.
    var contactRefreshToken: Int = 0
    /// Whether this is the last message from this sender before a different sender (for avatar grouping)
    var isLastFromSender: Bool = true
    /// Display style configuration
    var style: MessageBubbleStyle = .standard
    private let htmlContentHandler: HTMLContentHandler
    private let fullEmailOpener: any FullEmailOpening
    private let originalEmailSourceWarmer: any OriginalEmailSourceWarming

    @StateObject private var viewModel: MessageBubbleViewModel
    let onOpenFullMessage: (NSManagedObjectID, EmailReaderOpenSource) -> Void

    private var showHTMLPreview: Bool {
        guard resolvedForwardedDisplayContent == nil else {
            return false
        }

        guard !(message.isForwardedEmail && !viewModel.hasLoadedContent) else {
            return false
        }

        return MessageDisplayPolicy.shouldShowHTMLPreview(.init(
            hasHTMLSource: viewModel.htmlAnalysis.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isNewsletter: message.isNewsletter,
            hasRichHTMLContent: viewModel.hasRichHTMLContent,
            isFromMe: message.isFromMe,
            isOneToOneConversation: isEffectivelyOneToOneConversation,
            subject: message.subject,
            senderEmail: message.effectiveSenderEmail,
            isLikelyCalendarInvite: message.isLikelyCalendarInvite
        ))
    }

    private var resolvedForwardedDisplayContent: ForwardedMessageDisplayContent? {
        viewModel.forwardedDisplayContent ?? message.outgoingForwardedDisplayContent
    }

    @MainActor
    init(
        message: ChatMessageRowModel,
        messageBubbleLoader: any MessageBubbleLoading,
        htmlContentHandler: HTMLContentHandler,
        fullEmailOpener: any FullEmailOpening,
        originalEmailSourceWarmer: any OriginalEmailSourceWarming,
        prefetchedSenderName: String? = nil,
        isEffectivelyOneToOneConversation: Bool,
        contactRefreshToken: Int = 0,
        isLastFromSender: Bool = true,
        style: MessageBubbleStyle = .standard,
        onOpenFullMessage: @escaping (NSManagedObjectID, EmailReaderOpenSource) -> Void
    ) {
        self.message = message
        self.htmlContentHandler = htmlContentHandler
        self.fullEmailOpener = fullEmailOpener
        self.originalEmailSourceWarmer = originalEmailSourceWarmer
        self.prefetchedSenderName = prefetchedSenderName
        self.isEffectivelyOneToOneConversation = isEffectivelyOneToOneConversation
        self.contactRefreshToken = contactRefreshToken
        self.isLastFromSender = isLastFromSender
        self.style = style
        self.onOpenFullMessage = onOpenFullMessage
        self._viewModel = StateObject(wrappedValue: MessageBubbleViewModel(loader: messageBubbleLoader))
    }

    var body: some View {
        let currentLoadSignature = loadSignature
        let htmlAnalysis = viewModel.htmlAnalysis
        let showsCalendarInvitePreviewCard = showHTMLPreview && htmlAnalysis.supportsCalendarInvitePreviewCard

        HStack(alignment: .bottom, spacing: 8) {
            if !message.isFromMe {
                leadingContent
            } else {
                Spacer()
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                senderNameView

                subjectView(showsCalendarInvitePreviewCard: showsCalendarInvitePreviewCard)

                attachmentsView(hidingCalendarInviteAttachments: showsCalendarInvitePreviewCard)

                MessageContentView(
                    message: message,
                    style: style,
                    showHTMLPreview: showHTMLPreview,
                    hasHTMLSource: htmlAnalysis.hasHTMLSource,
                    fullTextContent: viewModel.fullTextContent,
                    fallbackPreviewText: message.fallbackPreviewText,
                    sharedDocumentLinks: viewModel.sharedDocumentLinks,
                    hasLoadedContent: viewModel.hasLoadedContent,
                    forwardedDisplayContent: resolvedForwardedDisplayContent,
                    fullEmailOpener: fullEmailOpener,
                    originalEmailSourceWarmer: originalEmailSourceWarmer,
                    htmlSourceSignaturer: htmlContentHandler,
                    onOpenFullMessage: openFullMessage(source:)
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
        .task(id: currentLoadSignature) {
            await viewModel.loadIfNeeded(using: loadContext(contentSignature: currentLoadSignature))
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
    private func subjectView(showsCalendarInvitePreviewCard: Bool) -> some View {
        if resolvedForwardedDisplayContent == nil,
           !(showHTMLPreview && (message.isNewsletter || showsCalendarInvitePreviewCard)),
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
        switch MessageSendStatusPresentation.resolve(
            deliveryState: message.outboundSendDeliveryState,
            isSendingLocalAttachments: message.isSendingLocalAttachments,
            hasFailedLocalAttachmentUploads: message.hasFailedLocalAttachmentUploads
        ) {
        case .sending:
            MessageSendingIndicator()
        case .notSent:
            Text(MessageSendStatusPresentation.notSent.label ?? "")
                .font(.caption2)
                .foregroundColor(.red)
        case .deliveryUnknown:
            Text(MessageSendStatusPresentation.deliveryUnknown.label ?? "")
                .font(.caption2)
                .foregroundColor(.orange)
        case .sendFailed:
            Text(MessageSendStatusPresentation.sendFailed.label ?? "")
                .font(.caption2)
                .foregroundColor(.red)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func attachmentsView(hidingCalendarInviteAttachments: Bool) -> some View {
        let displayable = message.displayableAttachments(
            using: viewModel.htmlAnalysis,
            hidingInlineReferencedInHTML: showHTMLPreview,
            hidingCalendarInviteAttachments: hidingCalendarInviteAttachments
        )
        if !displayable.isEmpty {
            if style.showAttachmentGrid {
                AttachmentGridView(attachments: displayable)
                    .frame(maxWidth: style.maxBubbleWidth)
            } else {
                AttachmentIndicator(count: displayable.count)
            }
        }
    }

    // MARK: - Helpers

    private var isGroupConversation: Bool {
        !isEffectivelyOneToOneConversation
    }

    private var senderRequest: MessageBubbleSenderRequest? {
        message.makeSenderRequest()
    }

    private func loadContext(contentSignature: String) -> MessageBubbleLoadContext {
        MessageBubbleLoadContext(
            messageID: message.id,
            contentSignature: contentSignature,
            prefetchedSenderName: prefetchedSenderName,
            senderRequest: senderRequest,
            contentRequest: message.makeContentRequest()
        )
    }

    private var loadSignature: String {
        message.loadSignatureComponents.signature(
            htmlSourceSignature: htmlContentHandler.htmlSourceSignature(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI
            ),
            contactRefreshToken: contactRefreshToken
        )
    }

    private func openFullMessage(source: EmailReaderOpenSource) {
        onOpenFullMessage(message.messageObjectID, source)
    }

    static func contentSignature(
        bodyStorageURI: String?,
        bodyText: String?,
        chatPreviewText: String? = nil,
        cleanedSnippet: String? = nil,
        snippet: String?,
        hasHTMLSource: Bool,
        htmlSourceSignature: String,
        contactRefreshToken: Int,
        senderEmail: String? = nil,
        senderDisplayName: String? = nil,
        senderHeaderDisplayName: String? = nil,
        senderAvatarURL: String? = nil
    ) -> String {
        MessageBubbleLoadSignatureComponents.signature(
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            chatPreviewText: chatPreviewText,
            cleanedSnippet: cleanedSnippet,
            snippet: snippet,
            hasHTMLSource: hasHTMLSource,
            htmlSourceSignature: htmlSourceSignature,
            contactRefreshToken: contactRefreshToken,
            senderEmail: senderEmail,
            senderDisplayName: senderDisplayName,
            senderHeaderDisplayName: senderHeaderDisplayName,
            senderAvatarURL: senderAvatarURL
        )
    }
}
