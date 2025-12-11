import SwiftUI
import CoreData
import Contacts

/// @deprecated Use ComposeView instead
/// This view is kept for backwards compatibility during migration
struct NewMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var session: AuthSession

    @State private var recipients: [Recipient] = []
    @State private var recipientQuery = ""
    @State private var messageText = ""
    @State private var showingAttachmentPicker = false
    @State private var isSearching = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showError = false

    let forwardedMessage: Message?

    private let sendService = GmailSendService(viewContext: CoreDataStack.shared.viewContext)

    init(forwardedMessage: Message? = nil) {
        self.forwardedMessage = forwardedMessage
    }

    @FocusState private var recipientFocused: Bool
    @FocusState private var messageFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Recipients section
                VStack(spacing: 0) {
                    RecipientInputView(
                        recipients: $recipients,
                        query: $recipientQuery,
                        isSearching: $isSearching,
                        isFocused: $recipientFocused
                    )

                    Divider()
                }

                // Contact search results
                if isSearching && !recipientQuery.isEmpty {
                    ContactSearchResults(
                        query: recipientQuery,
                        existingRecipients: recipients
                    ) { contact in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            recipients.append(Recipient(from: contact))
                            recipientQuery = ""
                            isSearching = false
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Spacer to push input to bottom
                Spacer()

                // Message input bar
                VStack(spacing: 0) {
                    Divider()

                    HStack(alignment: .bottom, spacing: 12) {
                        // Attachment button
                        Button(action: { showingAttachmentPicker = true }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.gray)
                        }

                        // Message input field
                        HStack(alignment: .bottom, spacing: 0) {
                            ZStack(alignment: .leading) {
                                if messageText.isEmpty {
                                    Text("iMessage")
                                        .foregroundColor(Color(.placeholderText))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                }

                                TextField("", text: $messageText, axis: .vertical)
                                    .focused($messageFocused)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .lineLimit(1...5)
                            }
                        }
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                        // Send button
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(canSend ? .blue : Color(.systemGray3))
                        }
                        .disabled(!canSend)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("New Message")
                        .font(.headline)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingAttachmentPicker) {
            AttachmentPicker(attachments: .constant([]))
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "Failed to send message")
        }
        .onAppear {
            if let forwardedMessage = forwardedMessage {
                setupForwardedMessage(forwardedMessage)
            }
            recipientFocused = true
        }
    }

    private var canSend: Bool {
        !recipients.isEmpty && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func sendMessage() {
        guard canSend else { return }

        isSending = true
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientEmails = recipients.map { $0.email }

        // Determine subject for forwarded message
        var messageSubject: String?
        if let forwardedMessage = forwardedMessage,
           let originalSubject = forwardedMessage.subject,
           !originalSubject.isEmpty {
            if originalSubject.lowercased().hasPrefix("fwd:") || originalSubject.lowercased().hasPrefix("fw:") {
                messageSubject = originalSubject
            } else {
                messageSubject = "Fwd: \(originalSubject)"
            }
        }

        Task {
            await MainActor.run {
                isSending = true
            }

            let optimisticMessageID = await MainActor.run {
                let message = sendService.createOptimisticMessage(
                    to: recipientEmails,
                    body: trimmedMessage,
                    subject: messageSubject
                )
                return message.id
            }

            do {
                let result = try await sendService.sendNew(
                    to: recipientEmails,
                    body: trimmedMessage,
                    subject: messageSubject,
                    attachmentInfos: []
                )

                await MainActor.run {
                    if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                        sendService.updateOptimisticMessage(optimisticMessage, with: result)
                    }
                    dismiss()
                }

                Task {
                    try? await SyncEngine.shared.performIncrementalSync()
                }
            } catch {
                await MainActor.run {
                    if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                        sendService.deleteOptimisticMessage(optimisticMessage)
                    }
                    errorMessage = error.localizedDescription
                    showError = true
                    isSending = false
                }
            }
        }
    }

    private func setupForwardedMessage(_ message: Message) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var quotedText = "\n\n---------- Forwarded message ---------\n"

        let participants = Array(message.conversation?.participants ?? [])

        if message.isFromMe {
            quotedText += "From: \(AuthSession.shared.userEmail ?? "Me")\n"
        } else {
            if let otherParticipant = participants.first(where: { participant in
                let email = participant.person?.email ?? ""
                return EmailNormalizer.normalize(email) != EmailNormalizer.normalize(AuthSession.shared.userEmail ?? "")
            })?.person {
                quotedText += "From: \(otherParticipant.name ?? otherParticipant.email)\n"
            }
        }

        quotedText += "Date: \(formatter.string(from: message.internalDate))\n"

        if let subject = message.subject, !subject.isEmpty {
            quotedText += "Subject: \(subject)\n"
        }

        let recipientList = participants.compactMap { $0.person?.email }
            .filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(AuthSession.shared.userEmail ?? "") }

        if !recipientList.isEmpty {
            quotedText += "To: \(recipientList.joined(separator: ", "))\n"
        }

        quotedText += "\n"

        if let snippet = message.snippet {
            quotedText += snippet
        }

        messageText = quotedText
    }
}
