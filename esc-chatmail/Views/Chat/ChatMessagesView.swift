import SwiftUI
import CoreData
import UIKit
import Contacts
import Combine

@MainActor
private final class ChatMessagesSession: ObservableObject {
    let scrollState: VirtualScrollState
    let coordinator: ChatMessagesCoordinator
    let messageBubbleLoader: MessageBubbleLoader

    private var cancellables = Set<AnyCancellable>()

    init(
        conversation: Conversation,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies
    ) {
        let scrollState = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: chatDependencies.storage.viewContext,
            makeBackgroundContext: chatDependencies.storage.makeBackgroundContext
        )
        self.scrollState = scrollState
        self.messageBubbleLoader = chatDependencies.content.makeMessageBubbleLoader()
        self.coordinator = ChatMessagesCoordinator(
            scrollState: scrollState,
            viewModel: viewModel,
            chatDependencies: chatDependencies,
            initialPresentationAnchor: .bottom
        )

        scrollState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

struct ChatMessagesView: View {
    let conversation: Conversation
    let viewModel: ChatViewModel
    let chatDependencies: ChatDependencies
    let isEffectivelyOneToOneConversation: Bool
    let isChatActiveAndUncovered: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    let onOpenFullMessage: (NSManagedObjectID, EmailReaderOpenSource) -> Void

    @StateObject private var session: ChatMessagesSession
    @State private var replyBarHeight: CGFloat = 0
    /// Height of the transcript's trailing spacer. Follows
    /// `ChatBottomInsetPolicy.Components.inset` through
    /// `handleBottomInsetChange` rather than being computed in `body`, so
    /// growth, and every change while the transcript is hidden, can be
    /// applied without the keyboard's animation (see
    /// `ChatBottomInsetPolicy.SpacerTransition` and `spacerTransition`). Only
    /// the spacer reads it: the initial-load overlays pad by the inset `body`
    /// computes live, which that policy's hidden branch relies on.
    @State private var transcriptBottomInset: CGFloat = 1
    @State private var transcriptOffsetShiftRequest: ChatTranscriptOffsetShifter.Request?
    @State private var transcriptShiftTracking = ChatTranscriptOffsetShifter.Tracking()
    @State private var isBottomAnchorVisible = false
    @GestureState private var isScrollGestureActive = false
    @ObservedObject private var keyboard = KeyboardResponder.shared
    @Namespace private var bottomID

    @MainActor
    init(
        conversation: Conversation,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        isEffectivelyOneToOneConversation: Bool,
        isChatActiveAndUncovered: Bool,
        isTextFieldFocused: FocusState<Bool>.Binding,
        onOpenFullMessage: @escaping (NSManagedObjectID, EmailReaderOpenSource) -> Void
    ) {
        self.conversation = conversation
        self.viewModel = viewModel
        self.chatDependencies = chatDependencies
        self.isEffectivelyOneToOneConversation = isEffectivelyOneToOneConversation
        self.isChatActiveAndUncovered = isChatActiveAndUncovered
        self.isTextFieldFocused = isTextFieldFocused
        self.onOpenFullMessage = onOpenFullMessage

        _session = StateObject(
            wrappedValue: ChatMessagesSession(
                conversation: conversation,
                viewModel: viewModel,
                chatDependencies: chatDependencies
            )
        )
    }

    private var scrollState: VirtualScrollState {
        session.scrollState
    }

    private var coordinator: ChatMessagesCoordinator {
        session.coordinator
    }

    var body: some View {
        ScrollViewReader { proxy in
            let displayedMessages = scrollState.visibleMessages
            let displayedMessageIDs = displayedMessages.map(\.objectID)
            let groupingMessages = senderGroupingMessages(for: displayedMessages)
            let groupingMessageIDs = groupingMessages.map(\.objectID)
            let keyboardOffset = keyboardAvoidanceOffset()
            let bottomInsetComponents = ChatBottomInsetPolicy.Components(
                replyBarHeight: replyBarHeight,
                keyboardOffset: keyboardOffset
            )
            let bottomContentInset = bottomInsetComponents.inset
            let initialLoadPhase = scrollState.initialLoadPhase
            let isWaitingForInitialWindow = initialLoadPhase == .loading
            let isInitialLoadUnavailable =
                initialLoadPhase == .empty || initialLoadPhase == .failed
            let isHidingInitialContent = !coordinator.isReadyToShow && !displayedMessages.isEmpty
            let shouldHideMessages =
                isWaitingForInitialWindow || isInitialLoadUnavailable || isHidingInitialContent

            ZStack(alignment: .bottom) {
                ZStack {
                    messagesScrollView(
                        displayedMessages: displayedMessages,
                        bottomContentInset: transcriptBottomInset,
                        scrollProxy: proxy
                    )
                    // Hidden under an opaque cover, not `.opacity(0)`, so the
                    // transcript is drawn throughout its hidden anchor pass
                    // and revealing it only removes the cover. "The chat opens
                    // blank until I scroll" persisted after #270 corrected
                    // every measured way of revealing it scrolled past its
                    // end, which leaves a reveal whose geometry reads correct
                    // while nothing is drawn: a subtree faded in from opacity
                    // 0 that does not repaint until a scroll. Not reproduced;
                    // with the cover there is nothing left to repaint. An
                    // overlay, so it never takes part in the layout the
                    // anchor pass measures. Touches pass through it: a drag
                    // during the hidden pass must still reach the scroll
                    // view's gesture below, which reveals the rows and
                    // cancels further forced anchoring, the reader's way out
                    // of a pass that is taking long. Taps and long presses
                    // are kept off the unseen bubbles by the rows themselves
                    // (`allowsHitTesting` on the lazy stack).
                    .overlay {
                        if shouldHideMessages {
                            Color(UIColor.systemBackground)
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityHidden(shouldHideMessages)
                    // Rows exist to touch only once the window has loaded;
                    // the scroll gesture stays available through the hidden
                    // anchor pass (see the cover above).
                    .allowsHitTesting(initialLoadPhase == .loaded)

                    if shouldHideMessages {
                        initialLoadOverlay(
                            phase: initialLoadPhase,
                            isWaitingForInitialAnchor: isHidingInitialContent,
                            bottomInset: bottomContentInset
                        )
                    }
                }

                replyBarOverlay(proxy: proxy)
                    .padding(.bottom, keyboardOffset)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onAppear {
                handleAppear(
                    proxy: proxy,
                    displayedMessages: displayedMessages,
                    groupingMessages: groupingMessages
                )
            }
            .onDisappear {
                coordinator.handleDisappear()
                scrollState.cleanup()
            }
            .onChange(of: groupingMessageIDs) { oldIDs, newIDs in
                handleDisplayedMessagesChange(
                    oldIDs: oldIDs,
                    newIDs: newIDs,
                    displayedMessages: displayedMessages,
                    groupingMessages: groupingMessages,
                    proxy: proxy
                )
            }
            .onChange(of: displayedMessageIDs) { _, _ in
                validateReplyTargetAfterMessageCollectionChange()
            }
            .onChange(of: scrollState.isInitialLoadComplete) { _, isComplete in
                handleInitialWindowLoaded(isComplete: isComplete, proxy: proxy)
            }
            .onChange(of: coordinator.isReadyToShow) { _, isReady in
                guard isReady else {
                    // The empty-to-loaded restart re-hides the transcript and
                    // re-runs the hidden anchor pass over rows the latest
                    // window load publishes; give it the same onAppear hold
                    // the first-open pass gets.
                    scrollState.beginInitialAnchorHold()
                    return
                }
                // The reveal (confirmed, fallback, or user takeover) ends the
                // hold that kept pre-reveal onAppear events from mutating the
                // virtual-scroll window mid-anchor.
                scrollState.endInitialAnchorHold()
                ChatViewPerformanceSignposts.contentReady(
                    conversationID: conversation.id.uuidString
                )
                logRevealedScrollPosition()
            }
            .onReceive(scrollState.insertedVisibleMessageEvents) { event in
                coordinator.handleInsertedVisibleMessageEvent(
                    event,
                    isChatActiveAndUncovered: isChatActiveAndUncovered,
                    isShowingLatestWindow: scrollState.isShowingLatestWindow,
                    isBottomAnchorVisible: isBottomAnchorVisible
                )
            }
            .onReceive(scrollState.refreshedInsertedMessageEvents) { refresh in
                coordinator.handleRefreshedInsertedMessageEvent(
                    refresh,
                    isChatActiveAndUncovered: isChatActiveAndUncovered,
                    isShowingLatestWindow: scrollState.isShowingLatestWindow
                )
            }
            .onChange(of: scrollState.totalMessageCount) { oldCount, newCount in
                validateReplyTargetAfterMessageCollectionChange()
                coordinator.handleMessageCountChange(
                    oldCount: oldCount,
                    newCount: newCount,
                    lastMessage: latestMessageForCoordinator(),
                    visibleMessages: scrollState.visibleMessages,
                    totalMessageCount: newCount,
                    stabilizeBottomAnchor: keyboard.currentHeight > 0 || isTextFieldFocused.wrappedValue,
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete,
                    isShowingLatestWindow: scrollState.isShowingLatestWindow,
                    isBottomAnchorVisible: isBottomAnchorVisible
                ) { performBottomAnchor($0, proxy: proxy) }
            }
            .onChange(of: bottomInsetComponents, initial: true) { oldComponents, newComponents in
                handleBottomInsetChange(from: oldComponents, to: newComponents, proxy: proxy)
            }
            .onChange(of: compensatesBottomInsetGrowth) { _, compensates in
                // A keyboard handed back to the composer without a hide (a
                // sheet dismissed while its own field was focused) can change
                // no inset at all; make up the growth owed while covered.
                guard compensates else { return }
                handleBottomInsetChange(
                    from: bottomInsetComponents,
                    to: bottomInsetComponents,
                    proxy: proxy
                )
            }
            .onChange(of: keyboard.currentHeight) { oldHeight, newHeight in
                coordinator.handleKeyboardHeightChange(
                    oldHeight: oldHeight,
                    newHeight: newHeight,
                    messageCount: totalMessageCountForCoordinator(),
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete,
                    // Same inputs, same update as handleBottomInsetChange's
                    // decision to shift the transcript for this growth.
                    isInsetGrowthCompensated: compensatesBottomInsetGrowth
                ) { performBottomAnchor($0, proxy: proxy) }
            }
            .onChange(of: isTextFieldFocused.wrappedValue) { _, isFocused in
                if isFocused { viewModel.prewarmReplySendCredentials() }
                coordinator.handleTextFieldFocusChange(
                    isFocused: isFocused,
                    messageCount: totalMessageCountForCoordinator(),
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete
                ) { performBottomAnchor($0, proxy: proxy) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                coordinator.handleContactStoreDidChange(senderGroupingMessages: senderGroupingMessages(for: scrollState.visibleMessages))
            }
            .onReceive(NotificationCenter.default.publisher(for: .personDisplayInfoDidChange).receive(on: DispatchQueue.main)) { notification in
                let groupingMessages = senderGroupingMessages(for: scrollState.visibleMessages)
                guard shouldRefreshForPersonDisplayInfoChange(notification, messages: groupingMessages) else { return }
                coordinator.handlePersonDisplayInfoDidChange(senderGroupingMessages: groupingMessages)
            }
        }
    }

    private func messagesScrollView(
        displayedMessages: [ChatMessageRowModel],
        bottomContentInset: CGFloat,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        GeometryReader { viewport in
            messagesScrollViewContent(
                displayedMessages: displayedMessages,
                bottomContentInset: bottomContentInset,
                viewportHeight: viewport.size.height,
                scrollProxy: scrollProxy
            )
        }
    }

    private func messagesScrollViewContent(
        displayedMessages: [ChatMessageRowModel],
        bottomContentInset: CGFloat,
        viewportHeight: CGFloat,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let newestRowIndex = MessageSendStatusLinePolicy.newestRowIndex(
            displayedRowCount: displayedMessages.count,
            isShowingLatestWindow: scrollState.isShowingLatestWindow
        )
        let localSendAppendedMessageIDs = scrollState.localSendAppendedMessageIDs
        return ScrollView {
            LazyVStack(spacing: 8) {
                // Keyed by display identity, not object ID, so Gmail's echo replacing a just-sent
                // reply updates the bubble in place instead of remounting it
                // (`ChatMessageDisplayIdentity`; uniqueness: `ChatTranscriptIdentityPolicy`).
                ForEach(ChatTranscriptIdentityPolicy.rows(for: displayedMessages)) { row in
                    let index = row.index
                    let message = row.message
                    let absoluteIndex = scrollState.absoluteIndex(forVisibleIndex: index) ?? index
                    let nextMessage = messageRow(atAbsoluteIndex: absoluteIndex + 1)
                    let isLastFromSender = ChatMessageRowGrouping.isLastFromSender(
                        current: message,
                        next: nextMessage,
                        senderRunKey: senderRunKey(for:)
                    )

                    MessageBubble(
                        message: message,
                        messageBubbleLoader: session.messageBubbleLoader,
                        htmlContentHandler: chatDependencies.content.htmlContentHandler,
                        fullEmailOpener: chatDependencies.fullEmailOpener,
                        originalEmailSourceWarmer: chatDependencies.content.originalEmailSourceWarmer,
                        isEffectivelyOneToOneConversation: isEffectivelyOneToOneConversation,
                        contactRefreshToken: coordinator.contactRefreshToken,
                        isLastFromSender: isLastFromSender,
                        isNewestInTranscript: index == newestRowIndex,
                        onOpenFullMessage: onOpenFullMessage,
                        onSendRecoveryAction: { action in
                            performSendRecovery(action, messageObjectID: message.messageObjectID)
                        }
                    )
                    .modifier(
                        ChatRowEntranceEffect(
                            animatesEntrance: localSendAppendedMessageIDs.contains(message.objectID)
                        )
                    )
                    .id(row.id)
                    .contentShape(Rectangle())
                    .contextMenu { messageContextMenu(for: message) } preview: {
                        MessageContextMenuPreview(message: message)
                    }
                    .onAppear { scrollState.markIndexVisible(absoluteIndex) }
                }

                Color.clear.frame(height: bottomContentInset)
                Color.clear
                    .frame(height: 1)
                    .id(bottomID)
                    .anchorPreference(key: ChatScrollGeometryPreferenceKey.self, value: .bounds) {
                        ChatScrollGeometryPreference(bottomAnchorBounds: $0)
                    }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .frame(minHeight: viewportHeight, alignment: .top)
            .transformAnchorPreference(
                key: ChatScrollGeometryPreferenceKey.self,
                value: .bounds
            ) { preference, contentBounds in
                preference.contentBounds = contentBounds
            }
            .contentShape(Rectangle())
            .onTapGesture { isTextFieldFocused.wrappedValue = false }
            // Bubbles under the cover must not take a tap (opening the
            // reader) or a long press (lifting a context-menu preview) the
            // reader cannot see. Scrolling is the scroll view's own gesture
            // and keeps working, so a drag during the hidden pass still
            // reveals (see the cover in `body`).
            .allowsHitTesting(coordinator.isReadyToShow)
        }
        // Anchor roles: `ChatTranscriptScrollAnchorPolicy`. The content end
        // is pinned while the transcript is hidden, so the window lands on
        // its newest rows and bubble growth cannot push the bottom anchor
        // off the viewport during the hidden anchor pass.
        .modifier(
            ChatTranscriptScrollAnchors(isTranscriptRevealed: isTranscriptRevealed)
        )
        .modifier(
            ChatTranscriptOffsetShifter(
                request: transcriptOffsetShiftRequest,
                tracking: transcriptShiftTracking,
                onUserScrollInteractionBegan: {
                    handleUserScrollPhaseBegan(scrollProxy: scrollProxy)
                },
                onUserScrollInteractionEnded: {
                    handleUserScrollPhaseEnded(scrollProxy: scrollProxy)
                }
            )
        )
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .updating($isScrollGestureActive) { _, isActive, _ in
                    isActive = true
                }
        )
        .onChange(of: isScrollGestureActive) { _, isActive in
            guard isActive else { return }
            handleUserScrollInteraction()
        }
        .overlayPreferenceValue(ChatScrollGeometryPreferenceKey.self) { preference in
            GeometryReader { geometryProxy in
                let frame = preference.bottomAnchorBounds
                    .map { geometryProxy[$0] } ?? .null
                let contentFrame = preference.contentBounds
                    .map { geometryProxy[$0] } ?? .null
                let geometry = ChatScrollGeometry(
                    bottomAnchorFrame: frame,
                    contentFrame: contentFrame,
                    viewportSize: geometryProxy.size
                )
                Color.clear
                    .id(scrollState.latestWindowLayoutID)
                    .onAppear {
                        handleBottomAnchorGeometryUpdate(
                            geometry: geometry,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: geometry) { _, newGeometry in
                        handleBottomAnchorGeometryUpdate(
                            geometry: newGeometry,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: coordinator.initialAnchorGeometryCheckID) { _, _ in
                        handleBottomAnchorGeometryUpdate(
                            geometry: geometry,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: isScrollGestureActive) { _, _ in
                        handleBottomAnchorGeometryUpdate(
                            geometry: geometry,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: coordinator.isUserScrollTakeoverActive) { _, _ in
                        handleBottomAnchorGeometryUpdate(
                            geometry: geometry,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
            }
            .allowsHitTesting(false)
        }
    }

    private func handleAppear(
        proxy: ScrollViewProxy,
        displayedMessages: [ChatMessageRowModel],
        groupingMessages: [ChatMessageRowModel]
    ) {
        scrollState.resume()
        if coordinator.isReadyToShow {
            // Re-appear after a completed reveal publishes no isReadyToShow
            // change, so release the initial-anchor hold here as well.
            scrollState.endInitialAnchorHold()
        }
        let messageCount = totalMessageCountForCoordinator()
        if let first = displayedMessages.first, let last = displayedMessages.last {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView appear conv=\(conversation.id.uuidString) messages=\(messageCount) visible=\(displayedMessages.count) first=\(first.id) \(first.internalDate) last=\(last.id) \(last.internalDate)",
                category: .ui
            )
        } else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView appear conv=\(conversation.id.uuidString) messages=\(messageCount) visible=0 initialLoaded=\(scrollState.isInitialLoadComplete)",
                category: .ui
            )
        }

        coordinator.handleAppear(
            messageCount: messageCount,
            lastMessage: latestMessageForCoordinator(),
            visibleMessages: scrollState.visibleMessages,
            senderGroupingMessages: groupingMessages,
            totalMessageCount: scrollState.totalMessageCount,
            isInitialWindowLoaded: scrollState.isInitialLoadComplete
        ) { performBottomAnchor($0, proxy: proxy) }
    }

    private func handleDisplayedMessagesChange(
        oldIDs: [NSManagedObjectID],
        newIDs: [NSManagedObjectID],
        displayedMessages: [ChatMessageRowModel],
        groupingMessages: [ChatMessageRowModel],
        proxy: ScrollViewProxy
    ) {
        coordinator.handleDisplayedMessagesChange(
            oldIDs: oldIDs,
            newIDs: newIDs,
            visibleMessages: displayedMessages,
            senderGroupingMessages: groupingMessages,
            messageCount: totalMessageCountForCoordinator(),
            totalMessageCount: scrollState.totalMessageCount,
            isInitialWindowLoaded: scrollState.isInitialLoadComplete
        ) { performBottomAnchor($0, proxy: proxy) }
    }

    private func handleInitialWindowLoaded(isComplete: Bool, proxy: ScrollViewProxy) {
        guard isComplete else { return }
        if coordinator.isReadyToShow && !coordinator.isRevealRestartableFromEmpty {
            // A re-publish of the initial window after a terminal reveal
            // (retry from the failure overlay, resume of an interrupted load)
            // re-arms the hold, but no isReadyToShow transition will ever
            // release it — the coordinator does not restart a reveal from a
            // non-empty ready state. Release it here: this onChange fires
            // after every initial-window publish. Empty-conversation
            // readiness is excluded: the coordinator restarts from it when
            // messages arrive, and that restarted hidden pass needs the hold
            // the re-publish just armed.
            scrollState.endInitialAnchorHold()
        }
        let visibleMessages = scrollState.visibleMessages
        viewModel.initializeReplyingTo(lastMessage: latestMessageForCoordinator())
        coordinator.handleInitialWindowLoaded(
            messageCount: totalMessageCountForCoordinator(),
            visibleMessages: visibleMessages,
            senderGroupingMessages: senderGroupingMessages(for: visibleMessages),
            totalMessageCount: scrollState.totalMessageCount
        ) { performBottomAnchor($0, proxy: proxy) }
    }

    private func replyBarOverlay(proxy: ScrollViewProxy) -> some View {
        ChatReplyComposerOverlay(
            composerState: viewModel.composerState,
            conversation: conversation,
            measuredHeight: $replyBarHeight,
            focusBinding: isTextFieldFocused
        ) {
            let anchorIntent = coordinator.beginLocalReplySend()
            defer { coordinator.endLocalReplySend(anchorIntent) }
            var persistedOptimisticMessageObjectID: NSManagedObjectID?
            let result = await viewModel.sendReply(
                onOptimisticMessagePersisted: { optimisticResult in
                    persistedOptimisticMessageObjectID =
                        optimisticResult.optimisticMessageObjectID
                    coordinator.handleReplyOptimisticMessagePersisted(
                        targetMessageID: optimisticResult.optimisticMessageObjectID,
                        anchorIntent: anchorIntent,
                        messageCount: totalMessageCountForCoordinator(),
                        totalMessageCount: scrollState.totalMessageCount,
                        isInitialWindowLoaded: scrollState.isInitialLoadComplete
                    ) { performBottomAnchor($0, proxy: proxy) }
                }
            )
            guard let result else {
                if let persistedOptimisticMessageObjectID {
                    coordinator.handleReplySendFailed(
                        targetMessageID: persistedOptimisticMessageObjectID
                    )
                }
                return false
            }

            coordinator.handleReplySendAdmitted(
                targetMessageID: result.optimisticMessageObjectID,
                anchorIntent: anchorIntent,
                messageCount: totalMessageCountForCoordinator(),
                totalMessageCount: scrollState.totalMessageCount,
                isInitialWindowLoaded: scrollState.isInitialLoadComplete
            ) { performBottomAnchor($0, proxy: proxy) }
            return true
        }
    }

    private func initialLoadPlaceholder(bottomInset: CGFloat) -> some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomInset)
            .accessibilityLabel("Loading messages")
    }

    @ViewBuilder
    private func initialLoadOverlay(
        phase: VirtualScrollState.InitialLoadPhase,
        isWaitingForInitialAnchor: Bool,
        bottomInset: CGFloat
    ) -> some View {
        switch phase {
        case .failed:
            ContentUnavailableView {
                SwiftUI.Label("Couldn’t Load Messages", systemImage: "exclamationmark.bubble")
            } description: {
                Text(scrollState.initialLoadFailureReason ?? "Please try again.")
            } actions: {
                Button("Try Again") {
                    scrollState.retryInitialLoad()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, bottomInset)

        case .empty:
            ContentUnavailableView {
                SwiftUI.Label("No Messages", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("There aren’t any visible messages in this conversation.")
            }
            .padding(.bottom, bottomInset)

        case .loading, .loaded:
            if phase == .loading || isWaitingForInitialAnchor {
                initialLoadPlaceholder(bottomInset: bottomInset)
                    .allowsHitTesting(false)
            }
        }
    }

    private func keyboardAvoidanceOffset() -> CGFloat {
        guard keyboard.isKeyboardVisible else { return 0 }
        return max(0, keyboard.currentHeight - currentBottomSafeAreaInset)
    }

    /// The initial window has loaded and the coordinator has revealed it. The
    /// one definition of "revealed" for the scroll anchors
    /// (`ChatTranscriptScrollAnchors`), the inset shift
    /// (`isTranscriptOffsetShiftAvailable`) and the spacer transition
    /// (`ChatBottomInsetPolicy.spacerTransition`): `ChatBottomInsetPolicy`
    /// assumes the `.top` size-change anchor `ChatTranscriptScrollAnchorPolicy`
    /// returns for a revealed transcript, so they must all read the same state.
    private var isTranscriptRevealed: Bool {
        scrollState.initialLoadPhase == .loaded && coordinator.isReadyToShow
    }

    /// Whether the transcript can be scrolled by inset shifts right now.
    private var isTranscriptOffsetShiftAvailable: Bool {
        ChatBottomInsetPolicy.isOffsetShiftAvailable(
            supportsOffsetShift: ChatTranscriptOffsetShifter.isSupported,
            isTranscriptRevealed: isTranscriptRevealed
        )
    }

    /// Whether inset growth in the current update is compensated by shifting
    /// the transcript. The coordinator's keyboard handler reads the same
    /// value in the same update (`isInsetGrowthCompensated`).
    private var compensatesBottomInsetGrowth: Bool {
        ChatBottomInsetPolicy.compensatesGrowth(
            isOffsetShiftAvailable: isTranscriptOffsetShiftAvailable,
            isChatActiveAndUncovered: isChatActiveAndUncovered,
            isComposerFocused: isTextFieldFocused.wrappedValue,
            isUserScrollGestureActive: isScrollGestureActive
        )
    }

    /// Applies a bottom-inset change (keyboard, "Replying to" row, wrapped
    /// draft lines, attachment strip) to the transcript spacer and scrolls the
    /// transcript so the content above the composer stays where it was
    /// instead of sliding under it. See `ChatBottomInsetPolicy` for which
    /// changes are compensated and why.
    private func handleBottomInsetChange(
        from oldComponents: ChatBottomInsetPolicy.Components,
        to newComponents: ChatBottomInsetPolicy.Components,
        proxy: ScrollViewProxy
    ) {
        let newInset = newComponents.inset
        switch ChatBottomInsetPolicy.spacerTransition(
            from: oldComponents,
            to: newComponents,
            isTranscriptRevealed: isTranscriptRevealed
        ) {
        case .immediate:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                transcriptBottomInset = newInset
            }
        case .keyboardAnimation:
            withAnimation(.easeOut(duration: keyboard.animationDuration)) {
                transcriptBottomInset = newInset
            }
        case .inherited:
            transcriptBottomInset = newInset
        }

        let now = ProcessInfo.processInfo.systemUptime
        let tracking = transcriptShiftTracking
        let inputs = ChatBottomInsetPolicy.ShiftInputs(
            oldComponents: oldComponents,
            newComponents: newComponents,
            observedOffsetY: tracking.contentOffsetY,
            bottomAnchorMaxY: tracking.bottomAnchorMaxY,
            viewportHeight: tracking.viewportHeight,
            isOffsetShiftAvailable: isTranscriptOffsetShiftAvailable,
            compensatesGrowth: compensatesBottomInsetGrowth,
            defersGrowth: ChatBottomInsetPolicy.defersGrowth(
                isOffsetShiftAvailable: isTranscriptOffsetShiftAvailable,
                isChatActiveAndUncovered: isChatActiveAndUncovered,
                isComposerFocused: isTextFieldFocused.wrappedValue
            ),
            isInteractiveDismissal: ChatBottomInsetPolicy.isInteractiveDismissal(
                isUserScrollInteractionActive: tracking.isUserScrollInteractionActive,
                lastUserScrollInteractionEndedAt: tracking.lastUserScrollInteractionEndedAt,
                now: now
            ),
            keyboardAnimationDuration: keyboard.animationDuration,
            now: now
        )
        guard let shift = ChatBottomInsetPolicy.shift(
            for: inputs,
            state: &tracking.shiftState
        ) else {
            return
        }

        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView bottom inset \(oldComponents.inset)->\(newInset); shifting transcript \(tracking.contentOffsetY)->\(shift.targetY) animated=\(shift.animationDuration != nil) takeover=\(coordinator.isUserScrollTakeoverActive)",
            category: .ui
        )
        if shift.direction == .towardNewer {
            coordinator.handleCompensatedInsetGrowth(
                settlingIn: shift.settleDuration
            ) { performBottomAnchor($0, proxy: proxy) }
        }
        scrollState.holdWindowForProgrammaticScroll(settlingIn: shift.settleDuration)
        transcriptOffsetShiftRequest = ChatTranscriptOffsetShifter.Request(
            id: UUID(),
            shift: shift
        )
    }

    /// The reader started moving the transcript by any means (drag,
    /// trackpad, mouse wheel): release the holds a programmatic inset shift
    /// placed on the coordinator's settle check and the virtual window, and
    /// hold off the coordinator's past-end correction until the scroll view
    /// comes to rest.
    private func handleUserScrollPhaseBegan(scrollProxy: ScrollViewProxy) {
        coordinator.handleUserScrollPhaseBegan()
        coordinator.handleUserScrollPhaseChange(isUserDriven: true) {
            performBottomAnchor($0, proxy: scrollProxy)
        }
        scrollState.handleUserScrollInteractionBegan()
    }

    /// The scroll view came to rest after the reader moved it.
    private func handleUserScrollPhaseEnded(scrollProxy: ScrollViewProxy) {
        coordinator.handleUserScrollPhaseChange(isUserDriven: false) {
            performBottomAnchor($0, proxy: scrollProxy)
        }
    }

    private func handleBottomAnchorGeometryUpdate(
        geometry: ChatScrollGeometry,
        layoutID: UUID,
        scrollProxy: ScrollViewProxy
    ) {
        let frame = geometry.bottomAnchorFrame
        let rawIsVisible = isBottomAnchorVisible(
            frame: frame,
            viewportSize: geometry.viewportSize
        )
        transcriptShiftTracking.bottomAnchorMaxY =
            frame.isNull || frame.isEmpty ? nil : frame.maxY
        transcriptShiftTracking.viewportHeight = geometry.viewportSize.height
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: rawIsVisible,
            // A null/empty frame means the lazy trailing anchor has not laid
            // out yet, which must not count against the initial retry budget.
            hasBottomAnchorGeometry: !frame.isNull && !frame.isEmpty,
            isUserScrollInteractionActive: isScrollGestureActive,
            contentMinY: geometry.contentFrame.isNull
                ? nil
                : geometry.contentFrame.minY,
            contentHeight: geometry.contentFrame.isNull
                ? nil
                : geometry.contentFrame.height,
            viewportHeight: geometry.viewportSize.height
        ) { performBottomAnchor($0, proxy: scrollProxy) }

        let isVisible =
            scrollState.initialLoadPhase == .loaded &&
            coordinator.isReadyToShow &&
            !isScrollGestureActive &&
            !coordinator.isUserScrollTakeoverActive &&
            rawIsVisible
        let becameVisible = !isBottomAnchorVisible && isVisible
        if isBottomAnchorVisible != isVisible {
            isBottomAnchorVisible = isVisible
        }
        scrollState.setFollowsLatestInsertions(isVisible)
        if becameVisible, scrollState.initialLoadPhase == .loaded {
            ChatViewPerformanceSignposts.bottomAnchorVisible(
                conversationID: conversation.id.uuidString
            )
        }
        coordinator.handleLatestWindowLayout(
            layoutID: layoutID,
            isChatActiveAndUncovered: isChatActiveAndUncovered,
            isShowingLatestWindow: scrollState.isShowingLatestWindow,
            isBottomAnchorVisible: isVisible
        )
    }

    /// Logs where UIKit has the transcript scrolled at the reveal next to where
    /// the anchor geometry puts its end. On iOS 26+ `contentOffsetY` comes
    /// from the scroll view itself (`ChatTranscriptOffsetShifter`), so in a
    /// blank open whose coordinator geometry reads correct, comparing
    /// `scrollOffsetY + anchorMaxY` with a good open's shows whether the two
    /// disagree. Below iOS 26 the offset is never tracked and reads 0.
    ///
    /// A `Log.diagnostic`, so it reaches only a Debug build launched from
    /// Xcode with ESC_LOG_DIAGNOSTICS=chat-view, never the field log the
    /// coordinator's always-on warnings write: it fires on every open, and
    /// nothing at the reveal tells a blank open from a good one.
    private func logRevealedScrollPosition() {
        let tracking = transcriptShiftTracking
        let anchorMaxY = tracking.bottomAnchorMaxY.map { String(format: "%.1f", $0) } ?? "nil"
        let viewportHeight = tracking.viewportHeight.map { String(format: "%.1f", $0) } ?? "nil"
        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView revealed rows=\(scrollState.visibleMessages.count) scrollOffsetY=\(String(format: "%.1f", tracking.contentOffsetY)) offsetTracked=\(ChatTranscriptOffsetShifter.isSupported) anchorMaxY=\(anchorMaxY) viewportHeight=\(viewportHeight)",
            category: .ui
        )
    }

    private func handleUserScrollInteraction() {
        if isBottomAnchorVisible {
            isBottomAnchorVisible = false
        }
        scrollState.setFollowsLatestInsertions(false)
        coordinator.handleUserScrollInteraction()
    }

    private func isBottomAnchorVisible(frame: CGRect, viewportSize: CGSize) -> Bool {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        return !frame.isNull && !frame.isEmpty && viewport.intersects(frame)
    }

    private var currentBottomSafeAreaInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = activeScene?.windows.first { $0.isKeyWindow } ?? activeScene?.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }

    private func totalMessageCountForCoordinator() -> Int {
        let loadedCount = max(scrollState.totalMessageCount, scrollState.visibleMessages.count)
        return scrollState.isInitialLoadComplete ? loadedCount : max(loadedCount, 1)
    }

    private func latestMessageForCoordinator() -> Message? {
        if scrollState.isShowingLatestWindow,
           let latestVisibleMessage = resolvedMessage(for: scrollState.visibleMessages.last) {
            return latestVisibleMessage
        }

        return viewModel.latestVisibleMessage()
    }

    private func validateReplyTargetAfterMessageCollectionChange() {
        let latestMessage = scrollState.isShowingLatestWindow
            ? latestMessageForCoordinator()
            : nil
        viewModel.updateReplyingToIfNewSubject(lastMessage: latestMessage)
    }

    private func resolvedMessage(for row: ChatMessageRowModel?) -> Message? {
        guard let row else { return nil }
        let context = chatDependencies.storage.viewContext
        if let registered = context.registeredObject(for: row.messageObjectID) as? Message, !registered.isDeleted {
            return registered
        }
        guard let resolved = try? context.existingObject(with: row.messageObjectID) as? Message, !resolved.isDeleted else {
            return nil
        }
        return resolved
    }

    @ViewBuilder
    private func messageContextMenu(for message: ChatMessageRowModel) -> some View {
        if message.outboundSendDeliveryState == .notSent {
            Button("Edit and resend", systemImage: "square.and.pencil") {
                performSendRecovery(.editAndResend, messageObjectID: message.messageObjectID)
            }
            Button("View send error", systemImage: "exclamationmark.circle") {
                viewModel.showReplyFailure(messageObjectID: message.messageObjectID)
            }
        } else if message.outboundSendDeliveryState == .deliveryUnknown {
            Button("Check delivery", systemImage: "arrow.clockwise") {
                performSendRecovery(.checkDelivery, messageObjectID: message.messageObjectID)
            }
        }
        // A just-sent bubble awaiting its echo is refused as a reply target
        // (sync is about to delete it), so do not offer a Reply that does
        // nothing.
        if message.outboundSendDeliveryState == .none && !message.isAwaitingSyncEcho {
            Button(action: { viewModel.setReplyingTo(messageObjectID: message.messageObjectID) }) {
                SwiftUI.Label("Reply", systemImage: "arrow.turn.up.left")
            }
        }
        Button(action: { viewModel.setMessageToForward(messageObjectID: message.messageObjectID) }) {
            SwiftUI.Label("Forward", systemImage: "arrow.turn.up.right")
        }
        if message.hasOriginalEmailContent {
            Button(action: { onOpenFullMessage(message.messageObjectID, .contextMenu) }) {
                SwiftUI.Label("View original email", systemImage: "doc.richtext")
            }
        }
    }

    /// The one route from a failed-send affordance (long-press menu, or the bubble's recovery
    /// dialog) into the view model's existing recovery paths. Neither adds a send path: Edit and
    /// Resend only refills the composer, and Check Delivery only re-reads Gmail.
    private func performSendRecovery(
        _ action: FailedSendRecoveryPolicy.Action,
        messageObjectID: NSManagedObjectID
    ) {
        switch action {
        case .editAndResend:
            if viewModel.editFailedReply(messageObjectID: messageObjectID) {
                isTextFieldFocused.wrappedValue = true
            }
        case .checkDelivery:
            viewModel.checkReplyDelivery(messageObjectID: messageObjectID)
        }
    }

    private func senderRunKey(for message: ChatMessageRowModel?) -> String? {
        coordinator.senderRunKey(
            for: message,
            isEffectivelyOneToOneConversation: isEffectivelyOneToOneConversation
        )
    }

    private func senderGroupingMessages(for displayedMessages: [ChatMessageRowModel]) -> [ChatMessageRowModel] {
        guard !displayedMessages.isEmpty else { return displayedMessages }
        guard let boundaryMessage = messageRow(atAbsoluteIndex: visibleRangeEndIndex(for: displayedMessages) + 1) else {
            return displayedMessages
        }
        guard displayedMessages.last?.objectID != boundaryMessage.objectID else { return displayedMessages }
        return displayedMessages + [boundaryMessage]
    }

    private func visibleRangeEndIndex(for displayedMessages: [ChatMessageRowModel]) -> Int {
        guard !displayedMessages.isEmpty else { return -1 }
        return scrollState.visibleRangeStartIndex + displayedMessages.count - 1
    }

    private func messageRow(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        guard index >= 0 else { return nil }
        return scrollState.rowForGrouping(atAbsoluteIndex: index)
    }

    private func shouldRefreshForPersonDisplayInfoChange(_ notification: Notification, messages: [ChatMessageRowModel]) -> Bool {
        let changedEmails = PersonDisplayInfoChangeNotification.emails(from: notification)
        guard !changedEmails.isEmpty else { return true }
        if !conversationParticipantEmails().isDisjoint(with: changedEmails) { return true }
        return messages.contains { message in
            [message.senderInfoEmail, message.effectiveSenderEmail, message.senderEmail]
                .compactMap { $0 }
                .map(EmailNormalizer.normalize)
                .contains { changedEmails.contains($0) }
        }
    }

    private func conversationParticipantEmails() -> Set<String> {
        Set((conversation.participants ?? [])
            .compactMap { $0.person?.email }
            .map(EmailNormalizer.normalize)
            .filter { !$0.isEmpty })
    }

    private func performBottomAnchor(_ step: ChatMessagesCoordinator.BottomAnchorStep, proxy: ScrollViewProxy) {
        ChatBottomInsetPolicy.coordinatorDidScroll(state: &transcriptShiftTracking.shiftState)
        if step.animated {
            withAnimation(.easeOut(duration: UIConfig.scrollAnimationDuration)) {
                Log.diagnostic(.chatView, level: .info, step.logMessage, category: .ui)
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } else {
            Log.diagnostic(.chatView, level: .info, step.logMessage, category: .ui)
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

private struct ChatReplyComposerOverlay: View {
    @ObservedObject var composerState: ChatComposerState
    let conversation: Conversation
    @Binding var measuredHeight: CGFloat
    var focusBinding: FocusState<Bool>.Binding
    let onSend: () async -> Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ChatReplyBar(
                replyText: $composerState.replyText,
                replyingTo: $composerState.replyingTo,
                attachments: $composerState.attachments,
                conversation: conversation,
                isSending: composerState.isSending,
                onSend: onSend,
                focusBinding: focusBinding,
                isProcessingAttachments: $composerState.isProcessingAttachments,
                unavailableReplyTargetURI: $composerState.unavailableReplyTargetURI,
                recoveredReplyEnvelope: composerState.recoveredReplyEnvelope
            )
        }
        .background(Color(UIColor.systemBackground))
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { measuredHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, newHeight in
                        measuredHeight = newHeight
                    }
            }
        )
    }
}

/// Applies `ChatTranscriptScrollAnchorPolicy` per `ScrollAnchorRole` on
/// iOS 18 and later, and the single `.top` anchor the transcript always used
/// below that.
private struct ChatTranscriptScrollAnchors: ViewModifier {
    let isTranscriptRevealed: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(
                    ChatTranscriptScrollAnchorPolicy.initialOffset,
                    for: .initialOffset
                )
                .defaultScrollAnchor(
                    ChatTranscriptScrollAnchorPolicy.sizeChanges(
                        isTranscriptRevealed: isTranscriptRevealed
                    ),
                    for: .sizeChanges
                )
                .defaultScrollAnchor(
                    ChatTranscriptScrollAnchorPolicy.alignment,
                    for: .alignment
                )
        } else {
            content.defaultScrollAnchor(.top)
        }
    }
}

private struct ChatScrollGeometryPreference {
    var bottomAnchorBounds: Anchor<CGRect>?
    var contentBounds: Anchor<CGRect>?

    init(
        bottomAnchorBounds: Anchor<CGRect>? = nil,
        contentBounds: Anchor<CGRect>? = nil
    ) {
        self.bottomAnchorBounds = bottomAnchorBounds
        self.contentBounds = contentBounds
    }
}

private struct ChatScrollGeometry: Equatable {
    let bottomAnchorFrame: CGRect
    let contentFrame: CGRect
    let viewportSize: CGSize
}

private struct ChatScrollGeometryPreferenceKey: PreferenceKey {
    static let defaultValue = ChatScrollGeometryPreference()

    static func reduce(
        value: inout ChatScrollGeometryPreference,
        nextValue: () -> ChatScrollGeometryPreference
    ) {
        let nextValue = nextValue()
        value.bottomAnchorBounds =
            nextValue.bottomAnchorBounds ?? value.bottomAnchorBounds
        value.contentBounds = nextValue.contentBounds ?? value.contentBounds
    }
}
