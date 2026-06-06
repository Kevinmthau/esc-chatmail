import SwiftUI
import CoreData
import UIKit
import Contacts
import Combine

/// Extracted from ChatView to keep SwiftUI type-checking manageable.
struct ChatMessagesView: View {
    let conversation: Conversation
    let messages: FetchedResults<Message>

    @ObservedObject var viewModel: ChatViewModel
    let chatDependencies: ChatDependencies
    var isTextFieldFocused: FocusState<Bool>.Binding
    let onOpenFullMessage: (NSManagedObjectID, EmailReaderOpenSource) -> Void
    @StateObject private var scrollState: VirtualScrollState
    @StateObject private var coordinator: ChatMessagesCoordinator
    @State private var replyBarHeight: CGFloat = 0

    @ObservedObject private var keyboard = KeyboardResponder.shared

    @Namespace private var bottomID

    @MainActor
    init(
        conversation: Conversation,
        messages: FetchedResults<Message>,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        isTextFieldFocused: FocusState<Bool>.Binding,
        onOpenFullMessage: @escaping (NSManagedObjectID, EmailReaderOpenSource) -> Void
    ) {
        self.conversation = conversation
        self.messages = messages
        self.viewModel = viewModel
        self.chatDependencies = chatDependencies
        self.isTextFieldFocused = isTextFieldFocused
        self.onOpenFullMessage = onOpenFullMessage
        let viewContext = chatDependencies.storage.viewContext
        let scrollState = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: chatDependencies.storage.makeBackgroundContext
        )
        _scrollState = StateObject(
            wrappedValue: scrollState
        )
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
            let isWaitingForInitialWindow = messages.count > 0 && !scrollState.isInitialLoadComplete
            let isHidingInitialContent = !coordinator.isReadyToShow && !displayedMessages.isEmpty
            let showsInitialPlaceholder = isWaitingForInitialWindow || isHidingInitialContent

            ZStack(alignment: .bottom) {
                ZStack {
                    if !isWaitingForInitialWindow {
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
                                    .contextMenu {
                                        messageContextMenu(for: message)
                                    } preview: {
                                        // Lightweight preview - just show the text content without triggering loads
                                        MessageContextMenuPreview(message: message)
                                    }
                                    .onAppear {
                                        scrollState.markIndexVisible(absoluteIndex)
                                    }
                                }

                                Color.clear
                                    .frame(height: bottomContentInset)
                                    .id(bottomID)
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isTextFieldFocused.wrappedValue = false
                            }
                        }
                        // Keep short conversations top-aligned; explicit scrollTo calls still
                        // move longer threads to the newest message when needed.
                        .defaultScrollAnchor(.top)
                        .scrollDismissesKeyboard(.interactively)
                        .opacity(isHidingInitialContent ? 0 : 1)
                    }

                    if showsInitialPlaceholder {
                        initialLoadPlaceholder(bottomInset: bottomContentInset)
                    }
                }

                replyBarOverlay
                    .padding(.bottom, keyboardOffset)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onAppear {
                if let first = messages.first, let last = messages.last {
                    Log.diagnostic(
                        .chatView,
                        level: .info,
                        "ChatView appear conv=\(conversation.id.uuidString) messages=\(messages.count) first=\(first.id) \(first.internalDate) last=\(last.id) \(last.internalDate)",
                        category: .ui
                    )
                } else {
                    Log.diagnostic(
                        .chatView,
                        level: .info,
                        "ChatView appear conv=\(conversation.id.uuidString) messages=\(messages.count) (empty)",
                        category: .ui
                    )
                }
                coordinator.handleAppear(
                    messageCount: messages.count,
                    lastMessage: messages.last,
                    visibleMessages: scrollState.visibleMessages,
                    senderGroupingMessages: senderGroupingMessages(for: scrollState.visibleMessages),
                    totalMessageCount: scrollState.totalMessageCount,
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete || messages.count == 0
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onDisappear {
                coordinator.handleDisappear()
            }
            .onChange(of: senderGroupingMessages(for: displayedMessages).map(\.objectID)) { oldIDs, newIDs in
                coordinator.handleDisplayedMessagesChange(
                    oldIDs: oldIDs,
                    newIDs: newIDs,
                    visibleMessages: displayedMessages,
                    senderGroupingMessages: senderGroupingMessages(for: displayedMessages),
                    messageCount: messages.count,
                    totalMessageCount: scrollState.totalMessageCount,
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onChange(of: scrollState.isInitialLoadComplete) { _, isComplete in
                guard isComplete else { return }

                let visibleMessages = scrollState.visibleMessages
                coordinator.handleInitialWindowLoaded(
                    messageCount: messages.count,
                    visibleMessages: visibleMessages,
                    senderGroupingMessages: senderGroupingMessages(for: visibleMessages),
                    totalMessageCount: scrollState.totalMessageCount
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                coordinator.handleMessageCountChange(
                    oldCount: oldCount,
                    newCount: newCount,
                    lastMessage: messages.last,
                    visibleMessages: scrollState.visibleMessages,
                    totalMessageCount: scrollState.totalMessageCount,
                    stabilizeBottomAnchor: keyboard.currentHeight > 0 || isTextFieldFocused.wrappedValue,
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onChange(of: keyboard.currentHeight) { oldHeight, newHeight in
                coordinator.handleKeyboardHeightChange(
                    oldHeight: oldHeight,
                    newHeight: newHeight,
                    messageCount: messages.count,
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onChange(of: isTextFieldFocused.wrappedValue) { _, isFocused in
                coordinator.handleTextFieldFocusChange(
                    isFocused: isFocused,
                    messageCount: messages.count,
                    isInitialWindowLoaded: scrollState.isInitialLoadComplete
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                coordinator.handleContactStoreDidChange(
                    senderGroupingMessages: senderGroupingMessages(for: scrollState.visibleMessages)
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .personDisplayInfoDidChange).receive(on: DispatchQueue.main)) { notification in
                let groupingMessages = senderGroupingMessages(for: scrollState.visibleMessages)
                guard shouldRefreshForPersonDisplayInfoChange(notification, messages: groupingMessages) else {
                    return
                }

                coordinator.handlePersonDisplayInfoDidChange(
                    senderGroupingMessages: groupingMessages
                )
            }
        }
    }

    private var replyBarOverlay: some View {
        VStack(spacing: 0) {
            Divider()
            ChatReplyBar(
                replyText: $viewModel.replyText,
                replyingTo: $viewModel.replyingTo,
                conversation: conversation,
                onSend: { attachments in
                    await viewModel.sendReply(with: attachments)
                },
                focusBinding: isTextFieldFocused
            )
        }
        .background(Color(UIColor.systemBackground))
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        replyBarHeight = geometry.size.height
                    }
                    .onChange(of: geometry.size.height) { _, newHeight in
                        replyBarHeight = newHeight
                    }
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
        guard keyboard.isKeyboardVisible else {
            return 0
        }

        return max(0, keyboard.currentHeight - currentBottomSafeAreaInset)
    }

    private var currentBottomSafeAreaInset: CGFloat {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = windowScenes.first { $0.activationState == .foregroundActive } ?? windowScenes.first
        let activeWindow = activeScene?.windows.first { $0.isKeyWindow } ?? activeScene?.windows.first
        return activeWindow?.safeAreaInsets.bottom ?? 0
    }

    @ViewBuilder
    private func messageContextMenu(for message: ChatMessageRowModel) -> some View {
        Button(action: {
            viewModel.setReplyingTo(messageObjectID: message.messageObjectID)
        }) {
            SwiftUI.Label("Reply", systemImage: "arrow.turn.up.left")
        }

        Button(action: {
            viewModel.setMessageToForward(messageObjectID: message.messageObjectID)
        }) {
            SwiftUI.Label("Forward", systemImage: "arrow.turn.up.right")
        }

        if message.hasOriginalEmailContent {
            Button(action: {
                onOpenFullMessage(message.messageObjectID, .contextMenu)
            }) {
                SwiftUI.Label("View original email", systemImage: "doc.richtext")
            }
        }
    }

    private func senderRunKey(for message: ChatMessageRowModel?) -> String? {
        coordinator.senderRunKey(
            for: message,
            isEffectivelyOneToOneConversation: viewModel.isEffectivelyOneToOneConversation
        )
    }

    private func senderGroupingMessages(
        for displayedMessages: [ChatMessageRowModel]
    ) -> [ChatMessageRowModel] {
        guard !displayedMessages.isEmpty else {
            return displayedMessages
        }

        guard let boundaryMessage = messageRow(atAbsoluteIndex: visibleRangeEndIndex(for: displayedMessages) + 1) else {
            return displayedMessages
        }

        guard displayedMessages.last?.objectID != boundaryMessage.objectID else {
            return displayedMessages
        }

        return displayedMessages + [boundaryMessage]
    }

    private func visibleRangeEndIndex(
        for displayedMessages: [ChatMessageRowModel]
    ) -> Int {
        guard !displayedMessages.isEmpty else {
            return -1
        }

        return scrollState.visibleRangeStartIndex + displayedMessages.count - 1
    }

    private func messageRow(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        guard index >= 0, index < messages.count else {
            return nil
        }

        return scrollState.row(atAbsoluteIndex: index) ?? ChatMessageRowModelMapper.map(messages[index])
    }

    private func shouldRefreshForPersonDisplayInfoChange(
        _ notification: Notification,
        messages: [ChatMessageRowModel]
    ) -> Bool {
        let changedEmails = PersonDisplayInfoChangeNotification.emails(from: notification)
        guard !changedEmails.isEmpty else { return true }

        if !conversationParticipantEmails().isDisjoint(with: changedEmails) {
            return true
        }

        return messages.contains { message in
            [
                message.senderInfoEmail,
                message.effectiveSenderEmail,
                message.senderEmail
            ]
            .compactMap { $0 }
            .map(EmailNormalizer.normalize)
            .contains { changedEmails.contains($0) }
        }
    }

    private func conversationParticipantEmails() -> Set<String> {
        Set(
            (conversation.participants ?? [])
                .compactMap { $0.person?.email }
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
    }

    private func performBottomAnchor(
        _ step: ChatMessagesCoordinator.BottomAnchorStep,
        proxy: ScrollViewProxy
    ) {
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
