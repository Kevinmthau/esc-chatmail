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
            let bottomContentInset = max(1, replyBarHeight + keyboardOffset)
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
                        bottomContentInset: bottomContentInset,
                        scrollProxy: proxy
                    )
                    .opacity(shouldHideMessages ? 0 : 1)
                    .accessibilityHidden(shouldHideMessages)
                    // Keep the scroll gesture available while loaded rows are
                    // waiting for their initial anchor. Taking control reveals
                    // the rows and cancels further forced anchoring.
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
            .onChange(of: keyboard.currentHeight) { oldHeight, newHeight in
                coordinator.handleKeyboardHeightChange(
                    oldHeight: oldHeight,
                    newHeight: newHeight,
                    messageCount: totalMessageCountForCoordinator(),
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete
                ) { performBottomAnchor($0, proxy: proxy) }
            }
            .onChange(of: isTextFieldFocused.wrappedValue) { _, isFocused in
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
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(displayedMessages.enumerated()), id: \.element.objectID) { index, message in
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
                        onOpenFullMessage: onOpenFullMessage
                    )
                    .id(message.objectID)
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
        }
        .defaultScrollAnchor(.top)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .updating($isScrollGestureActive) { _, isActive, _ in
                    isActive = true
                }
                .onChanged { _ in handleUserScrollInteraction() }
        )
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
        if coordinator.isReadyToShow {
            // A re-publish of the initial window after the reveal already
            // completed (retry from the failure overlay, resume of an
            // interrupted load) re-arms the hold, but no isReadyToShow
            // transition will ever release it — the coordinator refuses to
            // restart a reveal once ready. Release it here: this onChange
            // fires after every initial-window publish.
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
            let anchorIntent = coordinator.capturePostSendAnchorIntent()
            guard let result = await viewModel.sendReply() else { return false }

            coordinator.handleReplySendCompleted(
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
        if message.outboundSendDeliveryState == .none {
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
                focusBinding: focusBinding
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
