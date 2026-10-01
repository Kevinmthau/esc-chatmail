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
    /// Whether this row is the conversation's newest message
    /// (`MessageSendStatusLinePolicy.newestRowIndex`); only that row carries the "Sent" receipt.
    var isNewestInTranscript: Bool = false
    /// Display style configuration
    var style: MessageBubbleStyle = .standard
    private let htmlContentHandler: HTMLContentHandler
    private let fullEmailOpener: any FullEmailOpening
    private let originalEmailSourceWarmer: any OriginalEmailSourceWarming

    @StateObject private var viewModel: MessageBubbleViewModel
    /// Whether a pending send has outlasted `MessageSendStatusLinePolicy.sendingRevealDelay`.
    /// Driven by this view's own `.task`, so the timer dies with the row or the pending state.
    @State private var isSendingRevealDue = false
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
        isNewestInTranscript: Bool = false,
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
        self.isNewestInTranscript = isNewestInTranscript
        self.style = style
        self.onOpenFullMessage = onOpenFullMessage
        self._viewModel = StateObject(wrappedValue: MessageBubbleViewModel(loader: messageBubbleLoader))
    }

    var body: some View {
        let currentLoadSignature = loadSignature
        let htmlAnalysis = viewModel.htmlAnalysis
        let showsCalendarInvitePreviewCard = showHTMLPreview && htmlAnalysis.supportsCalendarInvitePreviewCard
        let displayableAttachments = message.displayableAttachments(
            using: htmlAnalysis,
            hidingInlineReferencedInHTML: showHTMLPreview,
            hidingCalendarInviteAttachments: showsCalendarInvitePreviewCard
        )
        let sendStatus = sendStatusPresentation
        let isSendPending = sendStatus == .sending
        let statusLine = MessageSendStatusLinePolicy.line(
            presentation: sendStatus,
            isSendingRevealDue: isSendingRevealDue,
            isFromMe: message.isFromMe,
            isNewestInTranscript: isNewestInTranscript
        )

        HStack(alignment: .bottom, spacing: 8) {
            if !message.isFromMe {
                leadingContent
            } else {
                Spacer()
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                senderNameView

                subjectView(showsCalendarInvitePreviewCard: showsCalendarInvitePreviewCard)

                attachmentsView(displayableAttachments)

                MessageContentView(
                    message: message,
                    style: style,
                    showHTMLPreview: showHTMLPreview,
                    hasHTMLSource: htmlAnalysis.hasHTMLSource,
                    fullTextContent: viewModel.fullTextContent,
                    fallbackPreviewText: message.fallbackPreviewText,
                    sharedDocumentLinks: viewModel.sharedDocumentLinks,
                    hasLoadedContent: viewModel.hasLoadedContent,
                    hasDisplayableAttachments: !displayableAttachments.isEmpty,
                    forwardedDisplayContent: resolvedForwardedDisplayContent,
                    fullEmailOpener: fullEmailOpener,
                    originalEmailSourceWarmer: originalEmailSourceWarmer,
                    htmlSourceSignaturer: htmlContentHandler,
                    onOpenFullMessage: openFullMessage(source:)
                )

                metadataLine(statusLine: statusLine)
            }
            .frame(maxWidth: style.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)

            if !message.isFromMe {
                Spacer()
            }
        }
        // Crossfades every status change (Sending… → Sent, → Not sent, → Delivery unknown, the
        // receipt moving to a newer row). None of them changes the row's height: the caption
        // shares the timestamp's line.
        .animation(.easeInOut(duration: 0.2), value: statusLine)
        .background {
            InlineAttachmentDownloadTrigger(
                attachments: InlineAttachmentDownloadPolicy.pendingImages(in: message.attachments, isFromMe: message.isFromMe)
            )
        }
        .task(id: currentLoadSignature) {
            await viewModel.loadIfNeeded(using: loadContext(contentSignature: currentLoadSignature))
        }
        .task(id: isSendPending) {
            await revealSendingAfterGracePeriod(isSendPending: isSendPending)
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

    private var sendStatusPresentation: MessageSendStatusPresentation {
        MessageSendStatusPresentation.resolve(
            deliveryState: message.outboundSendDeliveryState,
            isSendingLocalAttachments: message.isSendingLocalAttachments,
            hasFailedLocalAttachmentUploads: message.hasFailedLocalAttachmentUploads
        )
    }

    /// The timestamp, followed by the send status when there is one ("2:41 PM · Sent").
    private func metadataLine(statusLine: MessageSendStatusLinePolicy.Line?) -> some View {
        HStack(spacing: 0) {
            MessageMetadata(
                date: message.internalDate,
                isUnread: message.isUnread,
                showUnreadIndicator: style.showUnreadIndicator
            )

            // A ZStack so two captions crossfade in one place ("Sending…" fading out where
            // "Sent" fades in) instead of sitting side by side mid-transition.
            ZStack(alignment: .leading) {
                if let statusLine {
                    (Text(verbatim: " · ").foregroundColor(.secondary) +
                        Text(statusLine.label).foregroundColor(Self.statusColor(statusLine)))
                        .font(.caption2)
                        .lineLimit(1)
                        .id(statusLine)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Red for a definite failure. Orange for an ambiguous send: Gmail may already have it, and a
    /// red "failed" signal would invite a manual duplicate of a non-idempotent send.
    private static func statusColor(_ line: MessageSendStatusLinePolicy.Line) -> Color {
        switch line {
        case .notSent, .sendFailed:
            return .red
        case .deliveryUnknown:
            return .orange
        case .sending, .sent:
            return .secondary
        }
    }

    /// Flips `isSendingRevealDue` once a send has been pending for the grace period. `.task(id:)`
    /// cancels the wait the moment the pending state ends (Gmail answered, the send failed) or
    /// the row leaves the screen, so a fast send never shows "Sending…".
    private func revealSendingAfterGracePeriod(isSendPending: Bool) async {
        guard isSendPending else {
            if isSendingRevealDue {
                isSendingRevealDue = false
            }
            return
        }
        let delay = MessageSendStatusLinePolicy.remainingSendingRevealDelay(
            pendingSince: message.internalDate,
            now: Date()
        )
        if delay > 0 {
            guard await Task.sleepUnlessCancelled(nanoseconds: UInt64(delay * 1_000_000_000)) else {
                return
            }
        }
        isSendingRevealDue = true
    }

    @ViewBuilder
    private func attachmentsView(_ displayable: [ChatMessageAttachmentModel]) -> some View {
        if !displayable.isEmpty {
            if style.showAttachmentGrid {
                AttachmentGridView(
                    attachments: displayable,
                    inlineImagePresentations: Dictionary(uniqueKeysWithValues: displayable.map {
                        ($0.objectID, InlineImagePresentationPolicy.resolve(
                            attachment: $0,
                            isFromMe: message.isFromMe,
                            isHTMLPreview: showHTMLPreview,
                            bodyContentIDs: viewModel.htmlAnalysis.bodyInlineContentIDs,
                            hasLoadedAnalysis: viewModel.hasLoadedContent
                        ))
                    })
                )
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
