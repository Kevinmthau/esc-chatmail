import SwiftUI
import CoreData
import CryptoKit

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

    @StateObject private var viewModel: MessageBubbleViewModel
    let onOpenFullMessage: (NSManagedObjectID) -> Void

    private var showHTMLPreview: Bool {
        MessageDisplayPolicy.shouldShowHTMLPreview(
            hasHTMLSource: viewModel.htmlAnalysis.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isNewsletter: message.isNewsletter,
            hasRichHTMLContent: viewModel.hasRichHTMLContent,
            isFromMe: message.isFromMe,
            isOneToOneConversation: isEffectivelyOneToOneConversation,
            subject: message.subject,
            senderEmail: message.effectiveSenderEmail,
            isLikelyCalendarInvite: message.isLikelyCalendarInvite
        )
    }

    private var outgoingForwardedDisplayContent: ForwardedMessageDisplayContent? {
        viewModel.forwardedDisplayContent ?? message.outgoingForwardedDisplayContent
    }

    @MainActor
    init(
        message: ChatMessageRowModel,
        messageBubbleLoader: any MessageBubbleLoading,
        htmlContentHandler: HTMLContentHandler,
        prefetchedSenderName: String? = nil,
        isEffectivelyOneToOneConversation: Bool,
        contactRefreshToken: Int = 0,
        isLastFromSender: Bool = true,
        style: MessageBubbleStyle = .standard,
        onOpenFullMessage: @escaping (NSManagedObjectID) -> Void
    ) {
        self.message = message
        self.htmlContentHandler = htmlContentHandler
        self.prefetchedSenderName = prefetchedSenderName
        self.isEffectivelyOneToOneConversation = isEffectivelyOneToOneConversation
        self.contactRefreshToken = contactRefreshToken
        self.isLastFromSender = isLastFromSender
        self.style = style
        self.onOpenFullMessage = onOpenFullMessage
        self._viewModel = StateObject(wrappedValue: MessageBubbleViewModel(loader: messageBubbleLoader))
    }

    var body: some View {
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
    private func subjectView(showsCalendarInvitePreviewCard: Bool) -> some View {
        if outgoingForwardedDisplayContent == nil,
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
        if message.isSendingLocalAttachments {
            MessageSendingIndicator()
        } else if message.hasFailedLocalAttachmentUploads {
            Text("Send failed")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private func attachmentsView(hidingCalendarInviteAttachments: Bool) -> some View {
        let displayable = message.displayableAttachments(
            using: viewModel.htmlAnalysis,
            hidingInlineReferencedInHTML: showHTMLPreview,
            hidingCalendarInviteAttachments: hidingCalendarInviteAttachments
        )
        #if DEBUG
        let _ = {
            if message.hasAttachments {
                let attachmentDetails = message.attachments
                    .map { "[\($0.filename), cid:\($0.contentId ?? "nil")]" }
                    .joined(separator: ", ")
                Log.warning(
                    "UI_DEBUG msg=\(message.id) hasAttachments=\(message.hasAttachments) attachmentsArray=\(message.attachments.count) displayable=\(displayable.count) showHTMLPreview=\(showHTMLPreview) attachments=\(attachmentDetails)",
                    category: .ui
                )
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
    }

    // MARK: - Helpers

    private var isGroupConversation: Bool {
        !isEffectivelyOneToOneConversation
    }

    private var senderRequest: MessageBubbleSenderRequest? {
        message.makeSenderRequest()
    }

    private var loadContext: MessageBubbleLoadContext {
        MessageBubbleLoadContext(
            messageID: message.id,
            contentSignature: loadSignature,
            prefetchedSenderName: prefetchedSenderName,
            senderRequest: senderRequest,
            contentRequest: message.makeContentRequest()
        )
    }

    private var loadSignature: String {
        Self.contentSignature(
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            snippet: message.snippet,
            hasHTMLSource: message.hasHTMLSource,
            htmlSourceSignature: htmlContentHandler.htmlSourceSignature(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI
            ),
            contactRefreshToken: contactRefreshToken
        )
    }

    private func openFullMessage() {
        onOpenFullMessage(message.messageObjectID)
    }

    static func contentSignature(
        bodyStorageURI: String?,
        bodyText: String?,
        snippet: String?,
        hasHTMLSource: Bool,
        htmlSourceSignature: String,
        contactRefreshToken: Int
    ) -> String {
        "\(bodyStorageURI ?? "")|\(contentFingerprint(for: bodyText))|\(contentFingerprint(for: snippet))|\(hasHTMLSource)|source:\(htmlSourceSignature)|contacts:\(contactRefreshToken)"
    }

    private static func contentFingerprint(for text: String?) -> String {
        guard let text else { return "nil" }
        return SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
