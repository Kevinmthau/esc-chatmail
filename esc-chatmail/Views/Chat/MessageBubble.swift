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
    /// Where this row sits in its run of bubbles and what it draws above itself
    /// (`ChatTranscriptRunPolicy.placement`): the avatar's and the tail's row, the sender
    /// name's row, the time line.
    var runPlacement: ChatTranscriptRunPlacement = .alone
    /// The transcript's width, for a style whose text bubbles take a share of it
    /// (`MessageBubbleStyle.textBubbleMaxWidth`). 0 until the transcript has been laid out.
    var transcriptWidth: CGFloat = 0
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
    @Environment(\.layoutDirection) private var layoutDirection
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
    /// load's once published, before that the verdict stored on the row. Resolved from the
    /// row on every pass rather than seeded into the view model the way the HTML-source hint
    /// is (`MessageBubbleViewModel.init`): a seed is taken once per mount, and a verdict can
    /// be stamped while the bubble is mounted (the launch backfill, the refresher), which
    /// has to reach a row still waiting on its load.
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

    /// The row's own links until the load has published its own, so a row that renders before
    /// its load mounts with its document cards (`MessageDisplayPolicy.sharedDocumentLinks`).
    private var resolvedSharedDocumentLinks: [SharedDocumentLink] {
        MessageDisplayPolicy.sharedDocumentLinks(
            hasLoadedContent: viewModel.hasLoadedContent,
            loaded: viewModel.sharedDocumentLinks,
            stored: message.storedSharedDocumentLinks
        )
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
        runPlacement: ChatTranscriptRunPlacement = .alone,
        transcriptWidth: CGFloat = 0,
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
        self.runPlacement = runPlacement
        self.transcriptWidth = transcriptWidth
        self.isNewestInTranscript = isNewestInTranscript
        self.style = style
        self.onOpenFullMessage = onOpenFullMessage
        self.onSendRecoveryAction = onSendRecoveryAction
        // StateObject evaluates the request and memory-only analysis lookup once per mount.
        // A warm row starts with its resolved attachment layout; a cold row keeps its source
        // hint. Gmail's echo retains this view model and refreshes through loadIfNeeded.
        self._viewModel = StateObject(wrappedValue: MessageBubbleViewModel(
            loader: messageBubbleLoader,
            initialContentRequest: message.makeContentRequest()
        ))
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
        // The column holds text at the style's text width (the text's own cap where an image
        // can be wider: `MessageTextWidthCap`) and everything else at its own cap
        // (cards at `maxBubbleWidth`, images at `imageMaxWidth(transcriptWidth:)`), so it is as wide as the
        // widest of them. For a style whose widths are all `maxBubbleWidth` that is the 280
        // points it always was.
        let columnMaxWidth = max(
            style.textBubbleMaxWidth(transcriptWidth: transcriptWidth),
            style.imageMaxWidth(transcriptWidth: transcriptWidth) ?? 0
        )

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
                    sharedDocumentLinks: resolvedSharedDocumentLinks,
                    hasLoadedContent: viewModel.hasLoadedContent,
                    hasDisplayableAttachments: !displayableAttachments.isEmpty,
                    forwardedDisplayContent: resolvedForwardedDisplayContent,
                    fullEmailOpener: fullEmailOpener,
                    originalEmailSourceWarmer: originalEmailSourceWarmer,
                    htmlSourceSignaturer: htmlContentHandler,
                    onOpenFullMessage: openFullMessage(source:),
                    sendRecoveryPrompt: recoveryPrompt,
                    onSendRecoveryTap: { isShowingSendRecovery = true },
                    bubbleTail: MessageBubbleRowPolicy.tail(
                        style: style,
                        isFromMe: message.isFromMe,
                        endsRun: runPlacement.endsRun,
                        layoutDirection: layoutDirection
                    ),
                    textMaxWidth: style.textContentMaxWidth(transcriptWidth: transcriptWidth)
                )
                .alignmentGuide(Self.sendRecoveryBadgeAlignment) { $0[VerticalAlignment.center] }

                metadataLine(statusLine: statusLine, sendStatus: sendStatus)
            }
            .frame(maxWidth: columnMaxWidth, alignment: message.isFromMe ? .trailing : .leading)
            // Room for the bubble's tail on the row's own side, in every row of a style with
            // tails, so a bubble with one and a bubble without line up. Nothing where the
            // style has none.
            .padding(message.isFromMe ? .trailing : .leading, style.bubbleTailWidth)
            .modifier(MessageTimeTooltip(
                date: style.showsTimestampUnderBubble ? nil : message.internalDate
            ))

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
        // `MessageSendStatusLinePolicy.Arrangement`). Not where the caption has a line of its
        // own (`captionOnly`): there a status change can take that line off the row, and an
        // animated height animates the transcript's content size, which clamps a scroll issued
        // meanwhile (`ChatRowEntranceEffect`). That arrangement crossfades the caption inside
        // its line instead (`metadataLine`).
        .animation(
            style.showsTimestampUnderBubble ? .easeInOut(duration: 0.2) : nil,
            value: statusLine
        )
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
        // The time line, or the space that starts a run, above everything the row draws.
        .modifier(ChatTranscriptRowLeadIn(style: style, placement: runPlacement))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var leadingContent: some View {
        switch MessageBubbleRowPolicy.leadingSlot(
            style: style,
            isOneToOneConversation: isEffectivelyOneToOneConversation,
            endsRun: runPlacement.endsRun
        ) {
        case .none:
            EmptyView()
        case .avatar:
            BubbleAvatarView(
                name: viewModel.senderName ?? "?",
                avatarURL: viewModel.senderAvatarURL,
                imageData: viewModel.senderImageData
            )
        case .avatarPlaceholder:
            Color.clear.frame(width: 24, height: 24)
        }
    }

    @ViewBuilder
    private var senderNameView: some View {
        if MessageBubbleRowPolicy.showsSenderName(
            style: style,
            isFromMe: message.isFromMe,
            isGroupConversation: isGroupConversation,
            startsRun: runPlacement.startsRun
        ), let name = viewModel.senderName {
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
    private func metadataLine(
        statusLine: MessageSendStatusLinePolicy.Line?,
        sendStatus: MessageSendStatusPresentation
    ) -> some View {
        let timestamp = MessageMetadata(
            date: message.internalDate,
            isUnread: message.isUnread,
            showUnreadIndicator: style.showUnreadIndicator
        )
        switch MessageSendStatusLinePolicy.arrangement(
            showsTimestamp: style.showsTimestampUnderBubble,
            isAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
        ) {
        case .captionOnly:
            if MessageSendStatusLinePolicy.reservesCaptionLine(
                presentation: sendStatus,
                isFromMe: message.isFromMe,
                isNewestInTranscript: isNewestInTranscript
            ) {
                ZStack(alignment: message.isFromMe ? .trailing : .leading) {
                    // Holds the line's height while there is no caption, so one arriving
                    // ("Sending…" after the grace period, then "Sent") does not grow the row.
                    Text(MessageSendStatusLinePolicy.Line.sent.label)
                        .font(.caption2)
                        .hidden()
                    statusCaption(statusLine, form: .alone)
                }
                .lineLimit(1)
                // The crossfade the row's own animation gives the other arrangements, kept
                // inside the line so the line itself comes and goes unanimated.
                .animation(.easeInOut(duration: 0.2), value: statusLine)
            }
        case .inline:
            HStack(spacing: 0) {
                statusCaption(statusLine, form: .inline)
                    .lineLimit(1)
                    // If the column ever runs short, the timestamp gives way, not the status.
                    .layoutPriority(1)
                timestamp
                    // A wrapped timestamp would let a caption's arrival change the row's height.
                    .lineLimit(1)
            }
        case .stacked:
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 0) {
                statusCaption(statusLine, form: .stacked)
                timestamp
            }
        }
    }

    /// How the caption is drawn in each `MessageSendStatusLinePolicy.Arrangement`.
    private enum StatusCaptionForm {
        /// Before the timestamp, on its line: "Sent · ".
        case inline
        /// On its own line above the timestamp.
        case stacked
        /// On a line the row reserves for it, with no timestamp.
        case alone
    }

    /// A ZStack so two captions crossfade in one place ("Sending…" fading out where "Sent" fades
    /// in) instead of sitting side by side mid-transition, aligned on the bubble's side so both
    /// share one edge. Empty, it takes no space.
    private func statusCaption(
        _ statusLine: MessageSendStatusLinePolicy.Line?,
        form: StatusCaptionForm
    ) -> some View {
        ZStack(alignment: message.isFromMe ? .trailing : .leading) {
            if let statusLine {
                Group {
                    switch form {
                    case .inline:
                        // Interpolated rather than joined with `+`, which macOS 26 deprecates (and
                        // the Mac build's warnings-as-errors rejects); each part keeps its color.
                        let label = Text(statusLine.label).foregroundColor(Self.statusColor(statusLine))
                        let separator = Text(verbatim: " · ").foregroundColor(.secondary)
                        Text("\(label)\(separator)")
                    case .stacked:
                        // Own line: spacing lives inside the caption so an empty ZStack adds none.
                        Text(statusLine.label).foregroundColor(Self.statusColor(statusLine))
                            .padding(.bottom, 2)
                    case .alone:
                        Text(statusLine.label).foregroundColor(Self.statusColor(statusLine))
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
                            hasLoadedAnalysis: viewModel.hasResolvedHTMLAnalysis
                        ))
                    })
                )
                    .frame(maxWidth: max(
                        style.maxBubbleWidth,
                        style.imageMaxWidth(transcriptWidth: transcriptWidth) ?? 0
                    ))
                    // The style's image width, less in a transcript too narrow for it.
                    .environment(
                        \.imageAttachmentMaxWidth,
                        style.imageMaxWidth(transcriptWidth: transcriptWidth)
                    )
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
