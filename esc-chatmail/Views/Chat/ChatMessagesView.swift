import SwiftUI
import CoreData
import UIKit
import Contacts
import Combine

struct ChatMessagesView: View {
    let conversation: Conversation
    @ObservedObject var viewModel: ChatViewModel
    let chatDependencies: ChatDependencies
    let isChatActiveAndUncovered: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    let onOpenFullMessage: (NSManagedObjectID, EmailReaderOpenSource) -> Void

    @StateObject private var scrollState: VirtualScrollState
    @StateObject private var coordinator: ChatMessagesCoordinator
    @State private var replyBarHeight: CGFloat = 0
    @State private var isBottomAnchorVisible = false
    @ObservedObject private var keyboard = KeyboardResponder.shared
    @Namespace private var bottomID

    @MainActor
    init(
        conversation: Conversation,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        isChatActiveAndUncovered: Bool,
        isTextFieldFocused: FocusState<Bool>.Binding,
        onOpenFullMessage: @escaping (NSManagedObjectID, EmailReaderOpenSource) -> Void
    ) {
        self.conversation = conversation
        self.viewModel = viewModel
        self.chatDependencies = chatDependencies
        self.isChatActiveAndUncovered = isChatActiveAndUncovered
        self.isTextFieldFocused = isTextFieldFocused
        self.onOpenFullMessage = onOpenFullMessage

        let scrollState = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: chatDependencies.storage.viewContext,
            makeBackgroundContext: chatDependencies.storage.makeBackgroundContext
        )
        _scrollState = StateObject(wrappedValue: scrollState)
        _coordinator = StateObject(
            wrappedValue: ChatMessagesCoordinator(
                scrollState: scrollState,
                viewModel: viewModel,
                chatDependencies: chatDependencies
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            let displayedMessages = scrollState.visibleMessages
            let keyboardOffset = keyboardAvoidanceOffset()
            let bottomContentInset = max(1, replyBarHeight + keyboardOffset)
            let isWaitingForInitialWindow = !scrollState.isInitialLoadComplete
            let isHidingInitialContent = !coordinator.isReadyToShow && !displayedMessages.isEmpty

            ZStack(alignment: .bottom) {
                ZStack {
                    if !isWaitingForInitialWindow {
                        messagesScrollView(displayedMessages: displayedMessages, bottomContentInset: bottomContentInset)
                            .opacity(isHidingInitialContent ? 0 : 1)
                    }

                    if isWaitingForInitialWindow || isHidingInitialContent {
                        initialLoadPlaceholder(bottomInset: bottomContentInset)
                    }
                }

                replyBarOverlay(proxy: proxy)
                    .padding(.bottom, keyboardOffset)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onAppear { handleAppear(proxy: proxy, displayedMessages: displayedMessages) }
            .onDisappear { coordinator.handleDisappear() }
            .onChange(of: senderGroupingMessages(for: displayedMessages).map(\.objectID)) { oldIDs, newIDs in
                handleDisplayedMessagesChange(oldIDs: oldIDs, newIDs: newIDs, displayedMessages: displayedMessages, proxy: proxy)
            }
            .onChange(of: scrollState.isInitialLoadComplete) { _, isComplete in
                handleInitialWindowLoaded(isComplete: isComplete, proxy: proxy)
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

    private func messagesScrollView(displayedMessages: [ChatMessageRowModel], bottomContentInset: CGFloat) -> some View {
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
                        messageBubbleLoader: chatDependencies.content.makeMessageBubbleLoader(),
                        htmlContentHandler: chatDependencies.content.htmlContentHandler,
                        fullEmailOpener: chatDependencies.fullEmailOpener,
                        originalEmailSourceWarmer: chatDependencies.content.originalEmailSourceWarmer,
                        isEffectivelyOneToOneConversation: viewModel.isEffectivelyOneToOneConversation,
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
        .defaultScrollAnchor(.top)
        .scrollDismissesKeyboard(.interactively)
        .overlayPreferenceValue(ChatBottomAnchorBoundsPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                let frame = anchor.map { proxy[$0] } ?? .null
                Color.clear
                    .id(scrollState.latestWindowLayoutID)
                    .onAppear {
                        handleLatestWindowLayout(
                            frame: frame,
                            viewportSize: proxy.size,
                            layoutID: scrollState.latestWindowLayoutID
                        )
                    }
                    .onChange(of: frame) { _, newFrame in
                        updateBottomAnchorVisibility(frame: newFrame, viewportSize: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        updateBottomAnchorVisibility(frame: frame, viewportSize: newSize)
                    }
            }
            .allowsHitTesting(false)
        }
    }

    private func handleAppear(proxy: ScrollViewProxy, displayedMessages: [ChatMessageRowModel]) {
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
            senderGroupingMessages: senderGroupingMessages(for: scrollState.visibleMessages),
            totalMessageCount: scrollState.totalMessageCount,
            isInitialWindowLoaded: scrollState.isInitialLoadComplete
        ) { performBottomAnchor($0, proxy: proxy) }
    }

    private func handleDisplayedMessagesChange(
        oldIDs: [NSManagedObjectID],
        newIDs: [NSManagedObjectID],
        displayedMessages: [ChatMessageRowModel],
        proxy: ScrollViewProxy
    ) {
        coordinator.handleDisplayedMessagesChange(
            oldIDs: oldIDs,
            newIDs: newIDs,
            visibleMessages: displayedMessages,
            senderGroupingMessages: senderGroupingMessages(for: displayedMessages),
            messageCount: totalMessageCountForCoordinator(),
            totalMessageCount: scrollState.totalMessageCount,
            isInitialWindowLoaded: scrollState.isInitialLoadComplete
        ) { performBottomAnchor($0, proxy: proxy) }

        if oldIDs.last != newIDs.last, scrollState.isShowingLatestWindow {
            updateReplyTargetIfNewLatestMessageIsVisible()
        }
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
        VStack(spacing: 0) {
            Divider()
            ChatReplyBar(
                replyText: $viewModel.replyText,
                replyingTo: $viewModel.replyingTo,
                conversation: conversation,
                onSend: { attachments in
                    let didSend = await viewModel.sendReply(with: attachments)
                    if didSend {
                        coordinator.handleReplySendCompleted(
                            messageCount: totalMessageCountForCoordinator(),
                            totalMessageCount: scrollState.totalMessageCount,
                            isInitialWindowLoaded: scrollState.isInitialLoadComplete
                        ) { performBottomAnchor($0, proxy: proxy) }
                    }
                    return didSend
                },
                focusBinding: isTextFieldFocused
            )
        }
        .background(Color(UIColor.systemBackground))
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { replyBarHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, newHeight in replyBarHeight = newHeight }
            }
        )
    }

    private func initialLoadPlaceholder(bottomInset: CGFloat) -> some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomInset)
            .accessibilityLabel("Loading messages")
    }

    private func keyboardAvoidanceOffset() -> CGFloat {
        guard keyboard.isKeyboardVisible else { return 0 }
        return max(0, keyboard.currentHeight - currentBottomSafeAreaInset)
    }

    private func updateBottomAnchorVisibility(frame: CGRect, viewportSize: CGSize) {
        let isVisible = isBottomAnchorVisible(frame: frame, viewportSize: viewportSize)
        guard isBottomAnchorVisible != isVisible else { return }
        isBottomAnchorVisible = isVisible
    }

    private func handleLatestWindowLayout(
        frame: CGRect,
        viewportSize: CGSize,
        layoutID: UUID
    ) {
        let isVisible = isBottomAnchorVisible(frame: frame, viewportSize: viewportSize)
        if isBottomAnchorVisible != isVisible {
            isBottomAnchorVisible = isVisible
        }
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

    private func updateReplyTargetIfNewLatestMessageIsVisible() {
        guard let latestMessage = latestMessageForCoordinator() else { return }
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
        coordinator.senderRunKey(for: message, isEffectivelyOneToOneConversation: viewModel.isEffectivelyOneToOneConversation)
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

private struct ChatBottomAnchorBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}
