import SwiftUI
import CoreData

struct ChatView: View {
    @ObservedObject var conversation: Conversation
    @StateObject private var viewModel: ChatViewModel

    @FetchRequest private var messages: FetchedResults<Message>
    @ObservedObject private var keyboard = KeyboardResponder.shared
    @FocusState private var isTextFieldFocused: Bool
    @Namespace private var bottomID

    init(conversation: Conversation) {
        self.conversation = conversation
        self._viewModel = StateObject(wrappedValue: ChatViewModel(conversation: conversation))

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
        request.predicate = NSPredicate(format: "conversation == %@ AND NOT (ANY labels.id == %@)", conversation, "DRAFTS")
        request.fetchBatchSize = CoreDataConfig.fetchBatchSize
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments"]
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
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 80)
                .contentShape(Rectangle())
                .onTapGesture {
                    isTextFieldFocused = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                let unreadMessageIDs = messages.filter { $0.isUnread }.map { $0.objectID }
                viewModel.markConversationAsRead(messageObjectIDs: unreadMessageIDs)
                scrollToBottom(proxy: proxy, delay: UIConfig.initialScrollDelay)

                // Batch prefetch text content for visible messages (eliminates N+1 queries)
                Task.detached(priority: .userInitiated) {
                    let messageIds = await messages.map { $0.id }
                    await ProcessedTextCache.shared.prefetch(messageIds: messageIds)
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                if newCount > oldCount {
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
        .navigationTitle(conversation.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(conversation.displayName ?? "Chat")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isTextFieldFocused = false
                        viewModel.showingParticipantsList = true
                    }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { viewModel.archiveConversation() }) {
                        SwiftUI.Label("Archive", systemImage: "archivebox")
                    }

                    Button(action: { viewModel.togglePin() }) {
                        SwiftUI.Label(conversation.pinned ? "Unpin" : "Pin",
                              systemImage: conversation.pinned ? "pin.slash" : "pin")
                    }

                    Button(action: { viewModel.toggleMute() }) {
                        SwiftUI.Label(conversation.muted ? "Unmute" : "Mute",
                              systemImage: conversation.muted ? "bell" : "bell.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $viewModel.messageToForward) { message in
            ComposeView(mode: .forward(message))
        }
        .sheet(item: $viewModel.contactToAdd) { wrapper in
            AddContactView(contact: wrapper.contact)
        }
        .sheet(isPresented: $viewModel.showingContactPicker) {
            ContactPickerView(
                onContactSelected: { contact in
                    viewModel.handleContactSelected(contact)
                },
                onCancel: {
                    viewModel.handleContactPickerCancelled()
                }
            )
        }
        .sheet(isPresented: $viewModel.showingParticipantsList) {
            ParticipantsListView(
                conversation: conversation,
                onAddContact: { person in
                    viewModel.showContactActionSheet(for: person)
                },
                onEditContact: { identifier in
                    viewModel.editExistingContact(identifier: identifier)
                }
            )
        }
        .confirmationDialog(
            "Add Contact",
            isPresented: $viewModel.showingContactActionSheet,
            titleVisibility: .visible
        ) {
            Button("Create New Contact") {
                viewModel.createNewContact()
            }
            Button("Add to Existing Contact") {
                viewModel.addToExistingContact()
            }
            Button("Cancel", role: .cancel) {
                viewModel.personForContactAction = nil
            }
        } message: {
            if let person = viewModel.personForContactAction {
                Text("Add \(person.email) to your contacts")
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

    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
