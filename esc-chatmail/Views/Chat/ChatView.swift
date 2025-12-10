import SwiftUI
import WebKit
import CoreData
import Contacts
import ContactsUI

// MARK: - Text Processing Helpers (nonisolated for background thread usage)
private enum TextProcessing {
    static func extractPlainText(from html: String) -> String {
        var text = html

        // Remove script and style tags and their content
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        // Convert explicit line breaks to newlines
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression, range: nil)

        // Paragraphs and headings get double newlines (actual content breaks)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: .regularExpression, range: nil)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&#34;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")

        // Smart quotes and other typographic entities
        text = text.replacingOccurrences(of: "&ldquo;", with: "\"")
        text = text.replacingOccurrences(of: "&rdquo;", with: "\"")
        text = text.replacingOccurrences(of: "&lsquo;", with: "'")
        text = text.replacingOccurrences(of: "&rsquo;", with: "'")
        text = text.replacingOccurrences(of: "&#8220;", with: "\"")
        text = text.replacingOccurrences(of: "&#8221;", with: "\"")
        text = text.replacingOccurrences(of: "&#8216;", with: "'")
        text = text.replacingOccurrences(of: "&#8217;", with: "'")
        text = text.replacingOccurrences(of: "&ndash;", with: "–")
        text = text.replacingOccurrences(of: "&mdash;", with: "—")
        text = text.replacingOccurrences(of: "&#8211;", with: "–")
        text = text.replacingOccurrences(of: "&#8212;", with: "—")
        text = text.replacingOccurrences(of: "&hellip;", with: "…")
        text = text.replacingOccurrences(of: "&#8230;", with: "…")

        // Clean up whitespace
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression, range: nil)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    static func stripQuotedText(from text: String) -> String {
        var normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Collapse 3+ newlines into 2
        while normalizedText.contains("\n\n\n") {
            normalizedText = normalizedText.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        let lines = normalizedText.components(separatedBy: "\n")
        var newMessageLines: [String] = []
        var lastLineWasEmpty = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Stop at common quoted text markers
            if trimmedLine.starts(with: ">") ||
               (trimmedLine.starts(with: "On ") && trimmedLine.contains("wrote:")) ||
               (trimmedLine.starts(with: "From:") && index > 0) ||
               trimmedLine == "..." ||
               trimmedLine.contains("---------- Forwarded message ---------") ||
               trimmedLine.contains("________________________________") {
                break
            }

            // Skip consecutive empty lines
            let isEmptyLine = trimmedLine.isEmpty
            if isEmptyLine && lastLineWasEmpty {
                continue
            }
            lastLineWasEmpty = isEmptyLine

            newMessageLines.append(trimmedLine.isEmpty ? "" : line)
        }

        return newMessageLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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

                    Button(role: .destructive, action: { viewModel.deleteConversation() }) {
                        SwiftUI.Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $viewModel.messageToForward) { message in
            NewMessageView(forwardedMessage: message)
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

    private var otherParticipants: [Person] {
        let currentUserEmail = AuthSession.shared.userEmail?.lowercased() ?? ""
        guard let participants = conversation.participants else { return [] }

        return participants.compactMap { participant -> Person? in
            guard let person = participant.person else { return nil }
            guard person.email.lowercased() != currentUserEmail else { return nil }
            return person
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
                        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
                            Text(text)
                                .padding(10)
                                .background(message.isFromMe ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(message.isFromMe ? .white : .primary)
                                .cornerRadius(12)

                            if hasRichContent {
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

            if !message.isFromMe && isGroupConversation {
                await loadSenderName()
            }
            await loadFullTextContent()
            checkForRichContent()
        }
        .sheet(isPresented: $showingHTMLView) {
            HTMLMessageView(message: message)
        }
    }

    private var isGroupConversation: Bool {
        conversation.conversationType == .group || conversation.conversationType == .list
    }

    private func loadFullTextContent() async {
        let messageId = message.id
        let bodyText = message.value(forKey: "bodyText") as? String

        let processedText: String? = await Task.detached(priority: .userInitiated) {
            let handler = HTMLContentHandler.shared

            if handler.htmlFileExists(for: messageId),
               let html = handler.loadHTML(for: messageId) {
                let plainText = TextProcessing.extractPlainText(from: html)
                if !plainText.isEmpty {
                    return TextProcessing.stripQuotedText(from: plainText)
                }
            }

            if let text = bodyText {
                return TextProcessing.stripQuotedText(from: text)
            }
            return nil
        }.value

        fullTextContent = processedText
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

    private func checkForRichContent() {
        let messageId = message.id
        let isFromMe = message.isFromMe
        let isForwarded = message.isForwardedEmail
        let hasStorageURI = message.bodyStorageURI != nil

        Task.detached(priority: .userInitiated) {
            guard !isFromMe else {
                await MainActor.run { hasRichContent = false }
                return
            }

            let richContentResult: Bool
            if isForwarded {
                richContentResult = true
            } else if hasStorageURI {
                let handler = HTMLContentHandler.shared
                if handler.htmlFileExists(for: messageId),
                   let html = handler.loadHTML(for: messageId) {
                    let lowercased = html.lowercased()
                    let hasTable = lowercased.contains("<table")
                    let hasVideo = lowercased.contains("<video")
                    let hasIframe = lowercased.contains("<iframe")

                    richContentResult = hasTable || hasVideo || hasIframe
                } else {
                    richContentResult = false
                }
            } else {
                richContentResult = false
            }

            await MainActor.run { hasRichContent = richContentResult }
        }
    }
}
