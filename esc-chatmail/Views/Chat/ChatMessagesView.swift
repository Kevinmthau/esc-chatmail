import SwiftUI
import CoreData
import UIKit
import Contacts

/// Extracted from ChatView to keep SwiftUI type-checking manageable.
struct ChatMessagesView: View {
    let conversation: Conversation
    let messages: FetchedResults<Message>

    @ObservedObject var viewModel: ChatViewModel
    let deps: Dependencies
    var isTextFieldFocused: FocusState<Bool>.Binding
    let onOpenFullMessage: (Message) -> Void
    @StateObject private var scrollState: VirtualScrollState
    @StateObject private var coordinator: ChatMessagesCoordinator

    @ObservedObject private var keyboard = KeyboardResponder.shared

    @Namespace private var bottomID

    @MainActor
    init(
        conversation: Conversation,
        messages: FetchedResults<Message>,
        viewModel: ChatViewModel,
        deps: Dependencies,
        isTextFieldFocused: FocusState<Bool>.Binding,
        onOpenFullMessage: @escaping (Message) -> Void
    ) {
        self.conversation = conversation
        self.messages = messages
        self.viewModel = viewModel
        self.deps = deps
        self.isTextFieldFocused = isTextFieldFocused
        self.onOpenFullMessage = onOpenFullMessage
        let viewContext = deps.viewContext
        let coreDataStack = deps.coreDataStack
        let scrollState = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { coreDataStack.newBackgroundContext() }
        )
        _scrollState = StateObject(
            wrappedValue: scrollState
        )
        _coordinator = StateObject(
            wrappedValue: ChatMessagesCoordinator(
                scrollState: scrollState,
                viewModel: viewModel,
                participantLoader: deps.participantLoader
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
                        let nextMessage =
                            absoluteIndex + 1 < messages.count
                            ? messages[absoluteIndex + 1]
                            : nil
                        let isLastFromSender = nextMessage == nil ||
                            senderRunKey(for: nextMessage) != senderRunKey(for: message) ||
                            nextMessage?.isFromMe != message.isFromMe

                        MessageBubble(
                            message: message,
                            conversation: conversation,
                            deps: deps,
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
                    totalMessageCount: scrollState.totalMessageCount
                ) { step in
                    performBottomAnchor(step, proxy: proxy)
                }
            }
            .onDisappear {
                coordinator.handleDisappear()
            }
            .onChange(of: displayedMessages.map(\.objectID)) { oldIDs, newIDs in
                coordinator.handleDisplayedMessagesChange(
                    oldIDs: oldIDs,
                    newIDs: newIDs,
                    visibleMessages: displayedMessages,
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
                coordinator.handleContactStoreDidChange(visibleMessages: scrollState.visibleMessages)
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
    private func messageContextMenu(for message: Message) -> some View {
        Button(action: {
            viewModel.setReplyingTo(message)
        }) {
            SwiftUI.Label("Reply", systemImage: "arrow.turn.up.left")
        }

        Button(action: {
            viewModel.setMessageToForward(message)
        }) {
            SwiftUI.Label("Forward", systemImage: "arrow.turn.up.right")
        }
    }

    private func senderRunKey(for message: Message?) -> String? {
        coordinator.senderRunKey(
            for: message,
            isEffectivelyOneToOneConversation: viewModel.isEffectivelyOneToOneConversation
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
