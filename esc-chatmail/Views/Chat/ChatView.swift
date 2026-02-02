import SwiftUI
import CoreData

struct ChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var viewModel: ChatViewModel

    @FetchRequest private var messages: FetchedResults<Message>
    @ObservedObject private var keyboard = KeyboardResponder.shared
    @FocusState private var isTextFieldFocused: Bool
    @Namespace private var bottomID
    @State private var isReadyToShow = false
    @State private var initialScrollTask: Task<Void, Never>?
    @State private var scrollTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(conversation: Conversation) {
        self.conversation = conversation
        self._viewModel = StateObject(wrappedValue: ChatViewModel(conversation: conversation))

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
        request.predicate = NSPredicate(format: "conversation == %@ AND NOT (ANY labels.id == %@)", conversation, "DRAFT")
        request.fetchBatchSize = CoreDataConfig.fetchBatchSize
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments", "labels"]
        // Limit initial fetch for large conversations - LazyVStack handles virtualization
        let config = VirtualScrollConfiguration.default
        request.fetchLimit = config.pageSize * 2  // 100 messages initially
        self._messages = FetchRequest(fetchRequest: request)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
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
                    isTextFieldFocused = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .opacity(isReadyToShow ? 1 : 0)
            .onAppear {
                let unreadMessageIDs = messages.filter { $0.isUnread }.map { $0.objectID }
                viewModel.markConversationAsRead(messageObjectIDs: unreadMessageIDs)
                viewModel.initializeReplyingTo(lastMessage: messages.last)

                // If messages already loaded (Core Data cache), trigger initial scroll
                if !isReadyToShow && !messages.isEmpty {
                    performInitialScroll(proxy: proxy)
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
                // Cancel all tasks to prevent memory leaks
                initialScrollTask?.cancel()
                scrollTask?.cancel()
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
            .onChange(of: isTextFieldFocused) { _, isFocused in
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
                        focusBinding: $isTextFieldFocused
                    )
                    .background(Color(UIColor.systemBackground))
                }
            }
        }
        .navigationTitle(viewModel.resolvedDisplayName ?? conversation.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(viewModel.resolvedDisplayName ?? conversation.displayName ?? "Chat")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isTextFieldFocused = false
                        viewModel.contactManager.showingParticipantsList = true
                    }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { viewModel.archiveConversation() }) {
                        SwiftUI.Label("Archive", systemImage: "archivebox")
                    }

                    Button(action: {
                        viewModel.reportSpam()
                        dismiss()
                    }) {
                        SwiftUI.Label("Report Spam", systemImage: "exclamationmark.triangle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $viewModel.messageToForward) { message in
            ComposeView(mode: .forward(message))
        }
        .sheet(item: $viewModel.contactManager.contactToAdd) { wrapper in
            AddContactView(contact: wrapper.contact)
        }
        .sheet(isPresented: $viewModel.contactManager.showingContactPicker) {
            ContactPickerView(
                onContactSelected: { contact in
                    viewModel.contactManager.handleContactSelected(contact)
                },
                onCancel: {
                    viewModel.contactManager.handleContactPickerCancelled()
                }
            )
        }
        .sheet(isPresented: $viewModel.contactManager.showingParticipantsList) {
            ParticipantsListView(
                conversation: conversation,
                onCreateNewContact: { person in
                    viewModel.contactManager.createNewContact(for: person)
                },
                onAddToExistingContact: { person in
                    viewModel.contactManager.addToExistingContact(for: person)
                },
                onEditContact: { identifier in
                    viewModel.contactManager.editExistingContact(identifier: identifier)
                }
            )
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
        // Cancel any existing initial scroll task to prevent race conditions
        initialScrollTask?.cancel()
        initialScrollTask = Task { @MainActor in
            // Wait for layout to complete before scrolling
            try? await Task.sleep(nanoseconds: UInt64(UIConfig.contentChangeScrollDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if let lastMessage = messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
            isReadyToShow = true
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval) {
        // Cancel any existing scroll task to prevent accumulation from multiple onChange handlers
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: UIConfig.scrollAnimationDuration)) {
                if let lastMessage = messages.last {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                } else {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
    }

}
