import SwiftUI
import CoreData
import Contacts

struct NewMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var session: AuthSession
    
    @State private var recipients: [RecipientToken] = []
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
    
    @FocusState private var focusedField: Field?
    
    enum Field: Hashable {
        case recipients
        case message
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Recipients section
                VStack(spacing: 0) {
                    RecipientInputView(
                        recipients: $recipients,
                        query: $recipientQuery,
                        isSearching: $isSearching,
                        focusedField: _focusedField
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
                            recipients.append(RecipientToken(from: contact))
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
                                    .focused($focusedField, equals: .message)
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
            AttachmentPickerView { attachments in
                // Handle attachments
            }
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
            focusedField = .recipients
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
            // Add "Fwd: " prefix if not already present
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
            
            // Create optimistic message
            let optimisticMessage = await MainActor.run {
                sendService.createOptimisticMessage(
                    to: recipientEmails,
                    body: trimmedMessage,
                    subject: messageSubject
                )
            }
            
            do {
                // Send via Gmail API
                let result = try await sendService.sendNew(
                    to: recipientEmails,
                    body: trimmedMessage,
                    subject: messageSubject
                )
                
                await MainActor.run {
                    // Update optimistic message with real IDs
                    sendService.updateOptimisticMessage(optimisticMessage, with: result)
                    dismiss()
                }
                
                // Trigger sync to fetch the sent message
                Task {
                    try? await SyncEngine.shared.performIncrementalSync()
                }
            } catch {
                await MainActor.run {
                    // Delete optimistic message on failure
                    sendService.deleteOptimisticMessage(optimisticMessage)
                    errorMessage = error.localizedDescription
                    showError = true
                    isSending = false
                }
            }
        }
    }
    
    private func setupForwardedMessage(_ message: Message) {
        // Create quoted MIME format for forwarded message
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        var quotedText = "\n\n---------- Forwarded message ---------\n"
        
        // Get sender info from conversation participants
        let participants = Array(message.conversation?.participants ?? [])
        
        // Determine sender based on isFromMe flag
        if message.isFromMe {
            quotedText += "From: \(AuthSession.shared.userEmail ?? "Me")\n"
        } else {
            // Find the other participant (not the current user)
            if let otherParticipant = participants.first(where: { participant in
                let email = participant.person?.email ?? ""
                return EmailNormalizer.normalize(email) != EmailNormalizer.normalize(AuthSession.shared.userEmail ?? "")
            })?.person {
                quotedText += "From: \(otherParticipant.name ?? otherParticipant.email)\n"
            }
        }
        
        // Add Date
        quotedText += "Date: \(formatter.string(from: message.internalDate))\n"
        
        // Add Subject if exists
        if let subject = message.subject, !subject.isEmpty {
            quotedText += "Subject: \(subject)\n"
        }
        
        // Add recipients
        let recipientList = participants.compactMap { $0.person?.email }
            .filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(AuthSession.shared.userEmail ?? "") }
        
        if !recipientList.isEmpty {
            quotedText += "To: \(recipientList.joined(separator: ", "))\n"
        }
        
        quotedText += "\n"
        
        // Add message body
        if let snippet = message.snippet {
            quotedText += snippet
        }
        
        messageText = quotedText
    }
}

struct RecipientToken: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let email: String
    
    init(name: String, email: String) {
        self.name = name
        self.email = email
    }
    
    init(from contact: CNContact) {
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        self.name = fullName.isEmpty ? (contact.emailAddresses.first?.value as String? ?? "") : fullName
        self.email = contact.emailAddresses.first?.value as String? ?? ""
    }
    
    init(from person: Person) {
        self.name = person.name ?? person.email
        self.email = person.email
    }
}

// Attachment picker placeholder
struct AttachmentPickerView: View {
    let onSelection: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Text("Attachment Picker")
                    .font(.largeTitle)
                    .padding()
                
                Spacer()
            }
            .navigationTitle("Choose Attachment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}