import SwiftUI
import CoreData
import UIKit
import Contacts

/// Extracted from ChatView to keep SwiftUI type-checking manageable.
struct ChatMessagesView: View {
    let conversation: Conversation
    let messages: FetchedResults<Message>

    @ObservedObject var viewModel: ChatViewModel
    let chatDependencies: ChatDependencies
    var isTextFieldFocused: FocusState<Bool>.Binding
    let onOpenFullMessage: (NSManagedObjectID) -> Void
    @StateObject private var scrollState: VirtualScrollState
    @StateObject private var coordinator: ChatMessagesCoordinator

    @ObservedObject private var keyboard = KeyboardResponder.shared

    @Namespace private var bottomID

    @MainActor
    init(
        conversation: Conversation,
        messages: FetchedResults<Message>,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        isTextFieldFocused: FocusState<Bool>.Binding,
        onOpenFullMessage: @escaping (NSManagedObjectID) -> Void
    ) {
        self.conversation = conversation
        self.messages = messages
        self.viewModel = viewModel
        self.chatDependencies = chatDependencies
        self.isTextFieldFocused = isTextFieldFocused
        self.onOpenFullMessage = onOpenFullMessage
        let viewContext = chatDependencies.viewContext
        let scrollState = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: chatDependencies.makeBackgroundContext
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
                            messageBubbleLoader: chatDependencies.makeMessageBubbleLoader(),
                            htmlContentHandler: chatDependencies.htmlContentHandler,
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
                        .frame(height: 1)
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
                    totalMessageCount: scrollState.totalMessageCount
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
                    messageCount: messages.count
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                coordinator.handleMessageCountChange(
                    oldCount: oldCount,
                    newCount: newCount,
                    lastMessage: messages.last
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onChange(of: keyboard.currentHeight) { oldHeight, newHeight in
                coordinator.handleKeyboardHeightChange(
                    oldHeight: oldHeight,
                    newHeight: newHeight,
                    messageCount: messages.count
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onChange(of: isTextFieldFocused.wrappedValue) { _, isFocused in
                coordinator.handleTextFieldFocusChange(
                    isFocused: isFocused,
                    messageCount: messages.count
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                coordinator.handleContactStoreDidChange(
                    senderGroupingMessages: senderGroupingMessages(for: scrollState.visibleMessages)
                )
            }
            .safeAreaInset(edge: .bottom) {
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
                    .background(Color(UIColor.systemBackground))
                }
            }
        }
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
