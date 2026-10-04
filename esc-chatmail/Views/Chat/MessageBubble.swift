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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Whether a pending send has outlasted `MessageSendStatusLinePolicy.sendingRevealDelay`.
    /// Driven by this view's own `.task`, so the timer dies with the row or the pending state.
    @State private var isSendingRevealDue = false
    @State private var isShowingSendRecovery = false
    /// The failed-send dialog's chosen action, held until the dialog has dismissed
    /// (`FailedSendRecoveryPolicy.actionToRun`).
    @State private var pendingSendRecoveryAction: FailedSendRecoveryPolicy.Action?
    let onOpenFullMessage: (NSManagedObjectID, EmailReaderOpenSource) -> Void
    /// Runs an action the failed-send dialog offered. The caller routes it to the same view-model
    /// path as the long-press menu; the bubble never sends anything itself.
    let onSendRecoveryAction: (FailedSendRecoveryPolicy.Action) -> Void

    private var showHTMLPreview: Bool {
        guard resolvedForwardedDisplayContent == nil else {
            return false
        }

        guard !(message.isForwardedEmail && !viewModel.hasLoadedContent) else {
            return false
        }

        return MessageDisplayPolicy.shouldShowHTMLPreview(displayInput)
    }

    /// The row as the routing sees it. One value feeds both the routing above and the content
    /// view's loading-placeholder decision (`MessageDisplayPolicy.showsTextLoadingPlaceholder`),
    /// which asks the routing what a load could still decide: built separately, the two
    /// argument lists could drift, and there is no UI test target to notice.
    private var displayInput: MessageDisplayInput {
        MessageDisplayInput(
            hasHTMLSource: viewModel.htmlAnalysis.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isNewsletter: message.isNewsletter,
            hasRichHTMLContent: resolvedRichVerdict.hasRichHTMLContent,
            isFromMe: message.isFromMe,
            isOneToOneConversation: isEffectivelyOneToOneConversation,
            subject: message.subject,
            senderEmail: message.effectiveSenderEmail,
            isLikelyCalendarInvite: message.isLikelyCalendarInvite
        )
    }

    /// The verdict `displayInput` routes on and whether a load can still change it: the
    /// load's once published, before that the verdict stored on the row. Substituted here
    /// rather than seeded into the view model so it also covers the row's first pass, which
    /// runs before `loadIfNeeded` has touched the view model.
    private var resolvedRichVerdict: MessageDisplayPolicy.ResolvedRichVerdict {
        MessageDisplayPolicy.resolvedRichVerdict(
            hasLoadedContent: viewModel.hasLoadedContent,
            loadedHasRichHTMLContent: viewModel.hasRichHTMLContent,
            knownStoredVerdict: message.knownRichContentVerdict
        )
    }

    private var resolvedForwardedDisplayContent: ForwardedMessageDisplayContent? {
        viewModel.forwardedDisplayContent ?? message.outgoingForwardedDisplayContent
    }

    /// Vertical alignment that centers the failed-send badge on the content bubble. Defaults to
    /// center, so a row with no content bubble (attachments only) centers the badge on the column
    /// instead of hanging it below the row.
    private enum SendRecoveryBadgeAlignmentID: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    private static let sendRecoveryBadgeAlignment = VerticalAlignment(SendRecoveryBadgeAlignmentID.self)

    private struct LoadTaskID: Hashable {
        let messageID: String
        let signature: String
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
        onOpenFullMessage: @escaping (NSManagedObjectID, EmailReaderOpenSource) -> Void,
        onSendRecoveryAction: @escaping (FailedSendRecoveryPolicy.Action) -> Void
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
        self.onSendRecoveryAction = onSendRecoveryAction
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
            isConfirmedInGmail: message.isConfirmedInGmail,
            isNewestInTranscript: isNewestInTranscript
        )
        let recoveryPrompt = message.isFromMe
            ? FailedSendRecoveryPolicy.prompt(for: message.outboundSendDeliveryState)
            : nil

        // With a recovery badge, center it on the content bubble rather than on the row's
        // bottom (the timestamp line). Only then: the custom guide would also move an incoming
        // row's avatar off the bottom.
        HStack(alignment: recoveryPrompt == nil ? .bottom : Self.sendRecoveryBadgeAlignment, spacing: 8) {
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
                    displayInput: displayInput,
                    richVerdictIsKnown: resolvedRichVerdict.isKnown,
                    fullTextContent: viewModel.fullTextContent,
                    fallbackPreviewText: message.fallbackPreviewText,
                    sharedDocumentLinks: viewModel.sharedDocumentLinks,
                    hasLoadedContent: viewModel.hasLoadedContent,
                    hasDisplayableAttachments: !displayableAttachments.isEmpty,
                    forwardedDisplayContent: resolvedForwardedDisplayContent,
                    fullEmailOpener: fullEmailOpener,
                    originalEmailSourceWarmer: originalEmailSourceWarmer,
                    htmlSourceSignaturer: htmlContentHandler,
                    onOpenFullMessage: openFullMessage(source:),
                    sendRecoveryPrompt: recoveryPrompt,
                    onSendRecoveryTap: { isShowingSendRecovery = true }
                )
                .alignmentGuide(Self.sendRecoveryBadgeAlignment) { $0[VerticalAlignment.center] }

                metadataLine(statusLine: statusLine)
            }
            .frame(maxWidth: style.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)

            if let recoveryPrompt {
                // Trailing, as in iMessage; the room comes out of the leading spacer of the
                // outgoing row, whose bubble column is capped at `maxBubbleWidth`.
                sendRecoveryBadge(prompt: recoveryPrompt, statusLine: statusLine)
                    .alignmentGuide(Self.sendRecoveryBadgeAlignment) { $0[VerticalAlignment.center] }
                    .transition(.opacity)
            }

            if !message.isFromMe {
                Spacer()
            }
        }
        // Crossfades every status change (Sending… → Sent, → Not sent, → Delivery unknown, the
        // receipt moving to a newer row) and the badge's arrival. None of them changes the row's
        // height: the caption shares the timestamp's line (below accessibility text sizes; see
        // `MessageSendStatusLinePolicy.Arrangement`).
        .animation(.easeInOut(duration: 0.2), value: statusLine)
        .background {
            InlineAttachmentDownloadTrigger(
                attachments: InlineAttachmentDownloadPolicy.pendingImages(in: message.attachments, isFromMe: message.isFromMe)
            )
        }
        // Keyed on the message ID too: the transcript keeps this view (and its view model) when
        // Gmail's echo replaces an optimistic reply (`ChatMessageDisplayIdentity`), and the load
        // must re-run for the new message even if no signature input happened to change.
        .task(id: LoadTaskID(messageID: message.id, signature: currentLoadSignature)) {
            await viewModel.loadIfNeeded(using: loadContext(contentSignature: currentLoadSignature))
        }
        .task(id: isSendPending) {
            await revealSendingAfterGracePeriod(isSendPending: isSendPending)
        }
        .confirmationDialog(
            recoveryPrompt?.title ?? "",
            isPresented: $isShowingSendRecovery,
            titleVisibility: .visible,
            presenting: recoveryPrompt
        ) { prompt in
            ForEach(prompt.actions, id: \.self) { action in
                Button(action.title) {
                    pendingSendRecoveryAction = action
                    runPendingSendRecoveryIfDialogDismissed()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .onChange(of: isShowingSendRecovery) { _, _ in
            runPendingSendRecoveryIfDialogDismissed()
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

    /// The send status, when there is one, and the timestamp ("Sent · 2:41 PM"), arranged per
    /// `MessageSendStatusLinePolicy.Arrangement`.
    @ViewBuilder
    private func metadataLine(statusLine: MessageSendStatusLinePolicy.Line?) -> some View {
        let timestamp = MessageMetadata(
            date: message.internalDate,
            isUnread: message.isUnread,
            showUnreadIndicator: style.showUnreadIndicator
        )
        switch MessageSendStatusLinePolicy.arrangement(
            isAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
        ) {
        case .inline:
            HStack(spacing: 0) {
                statusCaption(statusLine, isInline: true)
                    .lineLimit(1)
                    // If the column ever runs short, the timestamp gives way, not the status.
                    .layoutPriority(1)
                timestamp
                    // A wrapped timestamp would let a caption's arrival change the row's height.
                    .lineLimit(1)
            }
        case .stacked:
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 0) {
                statusCaption(statusLine, isInline: false)
                timestamp
            }
        }
    }

    /// A ZStack so two captions crossfade in one place ("Sending…" fading out where "Sent" fades
    /// in) instead of sitting side by side mid-transition, aligned on the bubble's side so both
    /// share one edge. Empty, it takes no space.
    private func statusCaption(
        _ statusLine: MessageSendStatusLinePolicy.Line?,
        isInline: Bool
    ) -> some View {
        ZStack(alignment: message.isFromMe ? .trailing : .leading) {
            if let statusLine {
                Group {
                    if isInline {
                        Text(statusLine.label).foregroundColor(Self.statusColor(statusLine)) +
                            Text(verbatim: " · ").foregroundColor(.secondary)
                    } else {
                        // Own line: spacing lives inside the caption so an empty ZStack adds none.
                        Text(statusLine.label).foregroundColor(Self.statusColor(statusLine))
                            .padding(.bottom, 2)
                    }
                }
                .font(.caption2)
                .id(statusLine)
                .transition(.opacity)
            }
        }
    }

    private func sendRecoveryBadge(
        prompt: FailedSendRecoveryPolicy.Prompt,
        statusLine: MessageSendStatusLinePolicy.Line?
    ) -> some View {
        Button {
            isShowingSendRecovery = true
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundColor(statusLine.map(Self.statusColor) ?? .red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(prompt.title)
        .accessibilityHint(prompt.accessibilityHint)
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

    /// Runs the dialog's chosen action once the dialog is gone. Called from both the dialog button
    /// and the presentation change because SwiftUI does not promise which of the two lands first
    /// (the button's action, or `isPresented` turning false): whichever comes second finds both
    /// and dispatches exactly once. The extra main-actor turn lets SwiftUI finish the update that
    /// tears the dialog down, focus restoration included, before the action moves focus into the
    /// composer or raises an alert.
    private func runPendingSendRecoveryIfDialogDismissed() {
        guard let action = FailedSendRecoveryPolicy.actionToRun(
            pending: pendingSendRecoveryAction,
            isDialogPresented: isShowingSendRecovery
        ) else {
            return
        }
        pendingSendRecoveryAction = nil
        let onSendRecoveryAction = onSendRecoveryAction
        Task { @MainActor in
            onSendRecoveryAction(action)
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
            displayIdentityKey: message.bubbleContentIdentityKey,
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
