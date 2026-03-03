import SwiftUI
import CoreData
import UIKit

/// Extracted from ChatView to keep SwiftUI type-checking manageable.
struct ChatMessagesView: View {
    let conversation: Conversation
    let messages: FetchedResults<Message>

    @ObservedObject var viewModel: ChatViewModel
    var isTextFieldFocused: FocusState<Bool>.Binding

    @ObservedObject private var keyboard = KeyboardResponder.shared

    @Namespace private var bottomID
    @State private var isReadyToShow = false

    @State private var initialScrollTask: Task<Void, Never>?
    @State private var scrollTask: Task<Void, Never>?
    @State private var followUpScrollTask: Task<Void, Never>?
    @State private var stabilizationScrollTask: Task<Void, Never>?

    private var shouldUseBottomAnchoring: Bool { messages.count > 1 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(messages.indices, id: \.self) { index in
                        let message = messages[index]
                        let nextMessage = index + 1 < messages.count ? messages[index + 1] : nil
                        let isLastFromSender = nextMessage == nil ||
                            nextMessage?.senderEmail != message.senderEmail ||
                            nextMessage?.isFromMe != message.isFromMe

                        MessageBubble(
                            message: message,
                            conversation: conversation,
                            isLastFromSender: isLastFromSender
                        )
                        .id(message.id)
                        .contextMenu {
                            messageContextMenu(for: message)
                        } preview: {
                            // Lightweight preview - just show the text content without triggering loads
                            MessageContextMenuPreview(message: message)
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
#if DEBUG
                if let first = messages.first, let last = messages.last {
                    Log.info(
                        "ChatView appear conv=\(conversation.id.uuidString) messages=\(messages.count) first=\(first.id) \(first.internalDate) last=\(last.id) \(last.internalDate)",
                        category: .ui
                    )
                } else {
                    Log.info(
                        "ChatView appear conv=\(conversation.id.uuidString) messages=\(messages.count) (empty)",
                        category: .ui
                    )
                }
#endif
                let unreadMessages = messages.filter { $0.isUnread }
                let unreadMessageIDs = unreadMessages.map { $0.objectID }
                viewModel.markConversationAsRead(messageObjectIDs: unreadMessageIDs)
                viewModel.initializeReplyingTo(lastMessage: messages.last)

                // If messages already loaded (Core Data cache), trigger initial scroll
                if !isReadyToShow && !messages.isEmpty {
                    performInitialScroll(proxy: proxy)
                } else if messages.isEmpty {
                    // Avoid a permanently blank thread if there are no messages yet.
                    isReadyToShow = true
                }

                // Limit prefetch to visible + buffer messages (not all)
                let config = VirtualScrollConfiguration.default
                let prefetchLimit = config.visibleItemCount + config.bufferSize  // 30 messages

                // Collect data on MainActor (FetchedResults is not thread-safe)
                let recentMessages = messages.suffix(prefetchLimit)
                let messageIds = recentMessages.map { $0.id }
                let senderEmails = recentMessages.compactMap { $0.senderEmail }

                // Delegate prefetching to ViewModel
                viewModel.prefetchRecentContent(messageIds: messageIds, senderEmails: senderEmails)
                viewModel.loadResolvedDisplayName()
            }
            .onDisappear {
                // Cancel view-scoped scroll/prefetch work when leaving chat.
                initialScrollTask?.cancel()
                scrollTask?.cancel()
                followUpScrollTask?.cancel()
                stabilizationScrollTask?.cancel()
                viewModel.cancelPrefetch()
            }
            .onChange(of: messages.count) { oldCount, newCount in
                if !isReadyToShow && newCount > 0 {
                    // Initial load: trigger scroll with task tracking to prevent race conditions
                    performInitialScroll(proxy: proxy)
                } else if isReadyToShow && newCount > oldCount {
                    // New message arrived: animate the scroll
                    viewModel.updateReplyingToIfNewSubject(lastMessage: messages.last)
                    scrollToBottom(proxy: proxy, delay: UIConfig.contentChangeScrollDelay)
                }
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

    /// Performs the initial scroll to bottom with task tracking to prevent race conditions
    /// when both onAppear and onChange fire for cached data
    private func performInitialScroll(proxy: ScrollViewProxy) {
        guard shouldUseBottomAnchoring else {
            isReadyToShow = true
            return
        }
        // Cancel any existing initial scroll task to prevent race conditions
        initialScrollTask?.cancel()
        initialScrollTask = Task { @MainActor in
            // Wait for layout to complete before scrolling
            try? await Task.sleep(nanoseconds: UInt64(UIConfig.contentChangeScrollDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
#if DEBUG
            Log.info("ChatView initial scroll -> bottom anchor", category: .ui)
#endif
            proxy.scrollTo(bottomID, anchor: .bottom)
            await performFollowUpBottomScroll(proxy: proxy)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval) {
        guard shouldUseBottomAnchoring else { return }
        // Cancel any existing scroll task to prevent accumulation from multiple onChange handlers
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: UIConfig.scrollAnimationDuration)) {
#if DEBUG
                Log.info("ChatView animated scroll -> bottom anchor", category: .ui)
#endif
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func performFollowUpBottomScroll(proxy: ScrollViewProxy) async {
        guard shouldUseBottomAnchoring else {
            isReadyToShow = true
            return
        }
        followUpScrollTask?.cancel()
        followUpScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(UIConfig.initialScrollDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
#if DEBUG
            Log.info("ChatView follow-up scroll -> bottom anchor", category: .ui)
#endif
            proxy.scrollTo(bottomID, anchor: .bottom)
            isReadyToShow = true
            scheduleStabilizationBottomScrolls(proxy: proxy)
        }
        await followUpScrollTask?.value
    }

    /// Message rows can change height asynchronously (HTML/text processing),
    /// which can leave the viewport below content on some devices.
    /// Re-assert bottom anchoring briefly after initial load.
    private func scheduleStabilizationBottomScrolls(proxy: ScrollViewProxy) {
        guard shouldUseBottomAnchoring else { return }
        stabilizationScrollTask?.cancel()
        stabilizationScrollTask = Task { @MainActor in
            let delays: [TimeInterval] = [0.25, 0.75, 1.5]
            for delay in delays {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
#if DEBUG
                Log.info("ChatView stabilization scroll (\(delay)s) -> bottom anchor", category: .ui)
#endif
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}
