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

    @ObservedObject private var keyboard = KeyboardResponder.shared

    @Namespace private var bottomID
    @State private var isReadyToShow = false
    @State private var contactRefreshToken = 0
    @State private var senderGroupingKeysByEmail: [String: String] = [:]

    @State private var bottomAnchorTask: Task<Void, Never>?
    @State private var senderGroupingTask: Task<Void, Never>?

    private var shouldUseBottomAnchoring: Bool { messages.count > 1 }

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
        _scrollState = StateObject(
            wrappedValue: VirtualScrollState(
                conversationId: conversation.id.uuidString,
                initialWindowPosition: .end,
                viewContext: viewContext,
                makeBackgroundContext: { coreDataStack.newBackgroundContext() }
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
                            contactRefreshToken: contactRefreshToken,
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
                viewModel.markConversationAsReadIfNeeded()
                viewModel.initializeReplyingTo(lastMessage: messages.last)

                // If the newest window is already loaded (e.g. warm navigation), trigger initial scroll.
                if !isReadyToShow && !scrollState.visibleMessages.isEmpty {
                    performInitialScroll(proxy: proxy)
                } else if messages.isEmpty && scrollState.totalMessageCount == 0 {
                    // Avoid a permanently blank thread if there are no messages yet.
                    isReadyToShow = true
                }

                viewModel.loadResolvedDisplayName()
                prefetchVisibleContent()
                refreshSenderGroupingKeys(using: scrollState.visibleMessages)
            }
            .onDisappear {
                // Cancel view-scoped scroll/prefetch work when leaving chat.
                bottomAnchorTask?.cancel()
                senderGroupingTask?.cancel()
                viewModel.cancelPrefetch()
            }
            .onChange(of: displayedMessages.map(\.objectID)) { oldIDs, newIDs in
                if !isReadyToShow && !newIDs.isEmpty {
                    performInitialScroll(proxy: proxy)
                }

                if oldIDs != newIDs {
                    prefetchVisibleContent()
                    refreshSenderGroupingKeys(using: displayedMessages)
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                if !isReadyToShow && newCount > 0 {
                    performInitialScroll(proxy: proxy)
                } else if isReadyToShow && newCount > oldCount {
                    // New message arrived: animate the scroll
                    viewModel.updateReplyingToIfNewSubject(lastMessage: messages.last)
                    scrollToBottom(proxy: proxy, delay: UIConfig.contentChangeScrollDelay)
                }

                viewModel.loadResolvedDisplayName()
            }
            .onChange(of: keyboard.currentHeight) { oldHeight, newHeight in
                if newHeight > 0 || (oldHeight > 0 && newHeight == 0) {
                    scrollToBottom(proxy: proxy, delay: UIConfig.contentChangeScrollDelay)
                }
            }
            .onChange(of: isTextFieldFocused.wrappedValue) { _, isFocused in
                if !isFocused {
                    scrollToBottom(proxy: proxy, delay: UIConfig.initialScrollDelay)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                Task {
                    await ContactsResolver.shared.invalidateAllCache()
                    await PersonCache.shared.clearCache()
                    await MainActor.run {
                        contactRefreshToken &+= 1
                        viewModel.loadResolvedDisplayName()
                        refreshSenderGroupingKeys(using: scrollState.visibleMessages)
                    }
                }
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

    // MARK: - Scroll Helpers

    private func prefetchVisibleContent() {
        let config = VirtualScrollConfiguration.default
        let prefetchLimit = config.visibleItemCount + config.bufferSize
        let recentMessages = scrollState.visibleMessages.suffix(prefetchLimit)
        let messageIds = recentMessages.map(\.id)
        let senderEmails = recentMessages.compactMap(\.senderEmail)

        viewModel.prefetchRecentContent(messageIds: messageIds, senderEmails: senderEmails)
    }

    private func refreshSenderGroupingKeys(using visibleMessages: [Message]) {
        senderGroupingTask?.cancel()

        var uniqueSenderEmails: [String] = []
        var seenEmails = Set<String>()
        for message in visibleMessages {
            guard let email = senderEmail(for: message) else { continue }
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty,
                  seenEmails.insert(normalizedEmail).inserted else {
                continue
            }
            uniqueSenderEmails.append(email)
        }
        let participantLoader = deps.participantLoader

        senderGroupingTask = Task {
            let groupingKeys = await participantLoader.senderGroupingKeys(for: uniqueSenderEmails)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                senderGroupingKeysByEmail = groupingKeys
            }
        }
    }

    private func senderRunKey(for message: Message?) -> String? {
        guard let message else { return nil }
        guard !message.isFromMe else { return "me" }
        guard let senderEmail = senderEmail(for: message) else { return "email:" }

        let normalizedEmail = EmailNormalizer.normalize(senderEmail)
        if viewModel.isEffectivelyOneToOneConversation {
            return senderGroupingKeysByEmail[normalizedEmail] ?? "email:\(normalizedEmail)"
        }

        return "email:\(normalizedEmail)"
    }

    private func senderEmail(for message: Message) -> String? {
        if let senderEmail = message.senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !senderEmail.isEmpty {
            return senderEmail
        }

        return message.participants?
            .first(where: { $0.participantKind == .from })?
            .person?
            .email
    }

    /// Performs the initial scroll to bottom with task tracking to prevent race conditions
    /// when both onAppear and onChange fire for cached data
    private func performInitialScroll(proxy: ScrollViewProxy) {
        guard shouldUseBottomAnchoring else {
            isReadyToShow = true
            return
        }
        scheduleBottomAnchor(
            proxy: proxy,
            steps: [
                BottomAnchorStep(
                    delay: UIConfig.contentChangeScrollDelay,
                    animated: false,
                    logMessage: "ChatView initial scroll -> bottom anchor"
                ),
                BottomAnchorStep(
                    delay: UIConfig.initialScrollDelay,
                    animated: false,
                    logMessage: "ChatView follow-up scroll -> bottom anchor",
                    marksReady: true
                ),
                BottomAnchorStep(
                    delay: 0.25,
                    animated: false,
                    logMessage: "ChatView stabilization scroll (0.25s) -> bottom anchor"
                ),
                BottomAnchorStep(
                    delay: 0.75,
                    animated: false,
                    logMessage: "ChatView stabilization scroll (0.75s) -> bottom anchor"
                ),
                BottomAnchorStep(
                    delay: 1.5,
                    animated: false,
                    logMessage: "ChatView stabilization scroll (1.5s) -> bottom anchor"
                )
            ]
        )
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval) {
        guard shouldUseBottomAnchoring else { return }
        scheduleBottomAnchor(
            proxy: proxy,
            steps: [
                BottomAnchorStep(
                    delay: delay,
                    animated: true,
                    logMessage: "ChatView animated scroll -> bottom anchor"
                )
            ]
        )
    }

    private func scheduleBottomAnchor(
        proxy: ScrollViewProxy,
        steps: [BottomAnchorStep]
    ) {
        bottomAnchorTask?.cancel()
        bottomAnchorTask = Task { @MainActor in
            await scrollState.loadLatestWindowIfNeeded()

            for step in steps {
                if step.delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }

                if step.animated {
                    withAnimation(.easeOut(duration: UIConfig.scrollAnimationDuration)) {
                        Log.diagnostic(.chatView, level: .info, step.logMessage, category: .ui)
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                } else {
                    Log.diagnostic(.chatView, level: .info, step.logMessage, category: .ui)
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }

                if step.marksReady {
                    isReadyToShow = true
                }
            }
        }
    }
}

private struct BottomAnchorStep {
    let delay: TimeInterval
    let animated: Bool
    let logMessage: String
    var marksReady: Bool = false
}
