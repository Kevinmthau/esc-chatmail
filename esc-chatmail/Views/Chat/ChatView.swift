import SwiftUI
import WebKit
import CoreData
import Contacts
import ContactsUI

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
                    ForEach(messages) { message in
                        MessageBubble(message: message, conversation: conversation)
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
        .sheet(isPresented: $viewModel.showingParticipantsList) {
            ParticipantsListView(conversation: conversation) { person in
                viewModel.prepareContactToAdd(for: person)
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

// MARK: - Participants List View
struct ParticipantsListView: View {
    let conversation: Conversation
    let onAddContact: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    private let contactsResolver = ContactsResolver.shared
    private let participantLoader = ParticipantLoader.shared

    private var otherParticipants: [Person] {
        let currentUserEmail = AuthSession.shared.userEmail ?? ""
        let otherEmails = Set(participantLoader.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail
        ).map { EmailNormalizer.normalize($0) })

        guard let participants = conversation.participants else { return [] }
        return participants.compactMap { participant -> Person? in
            guard let person = participant.person else { return nil }
            return otherEmails.contains(EmailNormalizer.normalize(person.email)) ? person : nil
        }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(otherParticipants, id: \.email) { person in
                    ParticipantRow(person: person) {
                        onAddContact(person)
                    }
                }
            }
            .navigationTitle("Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ParticipantRow: View {
    let person: Person
    let onAddContact: () -> Void
    @State private var isExistingContact = false
    private let contactsResolver = ContactsResolver.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName ?? person.email)
                    .font(.body)
                if person.displayName != nil {
                    Text(person.email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isExistingContact {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button(action: onAddContact) {
                    Image(systemName: "person.badge.plus")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }
        }
        .task {
            if let match = await contactsResolver.lookup(email: person.email) {
                isExistingContact = match.displayName != nil
            }
        }
    }
}

// MARK: - Add Contact View
struct AddContactView: UIViewControllerRepresentable {
    let contact: CNMutableContact
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let contactVC = CNContactViewController(forNewContact: contact)
        contactVC.contactStore = CNContactStore()
        contactVC.delegate = context.coordinator

        let navController = UINavigationController(rootViewController: contactVC)
        navController.modalPresentationStyle = .formSheet
        return navController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator: NSObject, CNContactViewControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss()
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let conversation: Conversation
    /// Pre-loaded sender names from batch fetch (avoids N+1 queries)
    var prefetchedSenderName: String?

    private let contactsResolver = ContactsResolver.shared
    @State private var senderName: String?
    @State private var showingHTMLView = false
    @State private var hasRichContent = false
    @State private var fullTextContent: String?
    @State private var hasLoadedContent = false

    private var htmlContentHandler: HTMLContentHandler { HTMLContentHandler.shared }

    var body: some View {
        HStack {
            if message.isFromMe {
                Spacer()
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if !message.isFromMe && isGroupConversation && senderName != nil {
                    Text(senderName!)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }

                if let subject = message.subject, !subject.isEmpty {
                    Text(subject)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(message.isFromMe ? .secondary : .primary)
                }

                if let attachmentSet = message.value(forKey: "attachments") as? NSSet,
                   let attachments = attachmentSet.allObjects as? [Attachment], !attachments.isEmpty {
                    AttachmentGridView(attachments: attachments)
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.65)
                }

                if message.isNewsletter {
                    VStack(alignment: .leading, spacing: 8) {
                        if let text = fullTextContent ?? message.cleanedSnippet ?? message.snippet, !text.isEmpty {
                            Text(text)
                                .lineLimit(4)
                                .padding(10)
                                .background(Color.gray.opacity(0.2))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                                .frame(maxWidth: 260)
                        }

                        Button(action: {
                            showingHTMLView = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.richtext")
                                    .font(.caption)
                                Text("View Full Email")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption2)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                } else {
                    if let text = fullTextContent ?? message.cleanedSnippet ?? message.snippet, !text.isEmpty {
                        let isTruncated = text.components(separatedBy: .newlines).count > 25
                        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
                            Text(text)
                                .lineLimit(25)
                                .padding(10)
                                .background(message.isFromMe ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(message.isFromMe ? .white : .primary)
                                .cornerRadius(12)

                            if hasRichContent || isTruncated {
                                Button(action: {
                                    showingHTMLView = true
                                }) {
                                    HStack(spacing: 4) {
                                        Text("View Full Email")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Image(systemName: "arrow.up.forward")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    if message.isUnread {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }

                    Text(formatTime(message.internalDate))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 280, alignment: message.isFromMe ? .trailing : .leading)

            if !message.isFromMe {
                Spacer()
            }
        }
        .task {
            guard !hasLoadedContent else { return }
            hasLoadedContent = true

            // Use prefetched sender name if available, otherwise load
            if !message.isFromMe && isGroupConversation {
                if let prefetched = prefetchedSenderName {
                    senderName = prefetched
                } else {
                    await loadSenderName()
                }
            }

            // Try cache first (populated by batch prefetch in ChatView.onAppear)
            if let cached = await ProcessedTextCache.shared.get(messageId: message.id) {
                fullTextContent = cached.plainText
                hasRichContent = message.isForwardedEmail || (!message.isFromMe && cached.hasRichContent)
            } else {
                // Fallback: process on background thread and cache result
                await loadFullTextContentWithCache()
            }
        }
        .sheet(isPresented: $showingHTMLView) {
            HTMLMessageView(message: message)
        }
    }

    private var isGroupConversation: Bool {
        conversation.conversationType == .group || conversation.conversationType == .list
    }

    /// Loads and caches text content on background thread
    private func loadFullTextContentWithCache() async {
        let messageId = message.id
        let bodyText = message.value(forKey: "bodyText") as? String
        let isFromMe = message.isFromMe
        let isForwarded = message.isForwardedEmail

        let result: (plainText: String?, hasRichContent: Bool) = await Task.detached(priority: .userInitiated) {
            let handler = HTMLContentHandler.shared
            var processedResult = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

            // If no HTML content, try bodyText
            if processedResult.plainText == nil, let text = bodyText {
                processedResult = (TextProcessing.stripQuotedText(from: text), false)
            }

            // Cache the result for future use
            await ProcessedTextCache.shared.set(
                messageId: messageId,
                plainText: processedResult.plainText,
                hasRichContent: processedResult.hasRichContent
            )

            return processedResult
        }.value

        fullTextContent = result.plainText
        hasRichContent = isForwarded || (!isFromMe && result.hasRichContent)
    }

    private func loadSenderName() async {
        guard let participants = message.participants else { return }

        for participant in participants {
            if participant.participantKind == .from,
               let person = participant.person {
                let email = person.email

                if let personName = person.displayName, !personName.isEmpty {
                    senderName = personName
                    return
                }

                if let match = await contactsResolver.lookup(email: email),
                   let displayName = match.displayName {
                    senderName = displayName
                } else {
                    let normalized = EmailNormalizer.normalize(email)
                    if let atIndex = normalized.firstIndex(of: "@") {
                        senderName = String(normalized[..<atIndex])
                    } else {
                        senderName = email
                    }
                }
                return
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}
