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
            chatDependencies: chatDependencies
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
                guard isReady else { return }
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
                    isShowingLatestWindow: scrollState.isShowingLatestWindow
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
                    .anchorPreference(key: ChatBottomAnchorBoundsPreferenceKey.self, value: .bounds) {
                        $0
                    }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .onTapGesture { isTextFieldFocused.wrappedValue = false }
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in coordinator.handleUserScrollInteraction() }
        )
        .overlayPreferenceValue(ChatBottomAnchorBoundsPreferenceKey.self) { anchor in
            GeometryReader { geometryProxy in
                let frame = anchor.map { geometryProxy[$0] } ?? .null
                Color.clear
                    .id(scrollState.latestWindowLayoutID)
                    .onAppear {
                        handleBottomAnchorGeometryUpdate(
                            frame: frame,
                            viewportSize: geometryProxy.size,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: frame) { _, newFrame in
                        handleBottomAnchorGeometryUpdate(
                            frame: newFrame,
                            viewportSize: geometryProxy.size,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: geometryProxy.size) { _, newSize in
                        handleBottomAnchorGeometryUpdate(
                            frame: frame,
                            viewportSize: newSize,
                            layoutID: scrollState.latestWindowLayoutID,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: coordinator.initialAnchorGeometryCheckID) { _, _ in
                        handleBottomAnchorGeometryUpdate(
                            frame: frame,
                            viewportSize: geometryProxy.size,
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
            let didSend = await viewModel.sendReply()
            if didSend {
                coordinator.handleReplySendCompleted(
                    messageCount: totalMessageCountForCoordinator(),
                    totalMessageCount: scrollState.totalMessageCount,
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete
                ) { performBottomAnchor($0, proxy: proxy) }
            }
            return didSend
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
        frame: CGRect,
        viewportSize: CGSize,
        layoutID: UUID,
        scrollProxy: ScrollViewProxy
    ) {
        let isVisible = isBottomAnchorVisible(frame: frame, viewportSize: viewportSize)
        let becameVisible = !isBottomAnchorVisible && isVisible
        if isBottomAnchorVisible != isVisible {
            isBottomAnchorVisible = isVisible
        }
        if becameVisible, scrollState.initialLoadPhase == .loaded {
            ChatViewPerformanceSignposts.bottomAnchorVisible(
                conversationID: conversation.id.uuidString
            )
        }
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: isVisible
        ) { performBottomAnchor($0, proxy: scrollProxy) }
        coordinator.handleLatestWindowLayout(
            layoutID: layoutID,
            isChatActiveAndUncovered: isChatActiveAndUncovered,
            isShowingLatestWindow: scrollState.isShowingLatestWindow,
            isBottomAnchorVisible: isVisible
        )
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
        if let latestVisibleMessage = resolvedMessage(for: scrollState.visibleMessages.last) {
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
        Button(action: { viewModel.setReplyingTo(messageObjectID: message.messageObjectID) }) {
            SwiftUI.Label("Reply", systemImage: "arrow.turn.up.left")
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

private struct ChatBottomAnchorBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}
