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
        .onAppear {
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
        
        // Create or find conversation
        Task {
            do {
                let conversation = try await findOrCreateConversation(with: recipientEmails)
                
                // Create message optimistically
                await MainActor.run {
                    let message = Message(context: viewContext)
                    message.id = UUID().uuidString
                    message.gmThreadId = UUID().uuidString
                    message.internalDate = Date()
                    message.snippet = trimmedMessage
                    message.cleanedSnippet = trimmedMessage
                    message.isFromMe = true
                    message.conversation = conversation
                    message.isUnread = false
                    message.hasAttachments = false
                    
                    conversation.lastMessageTime = Date()
                    conversation.lastMessagePreview = trimmedMessage
                    
                    do {
                        try viewContext.save()
                        dismiss()
                    } catch {
                        print("Failed to save message: \(error)")
                        isSending = false
                    }
                }
                
                // TODO: Send via API when available
                // if let userEmail = session.userEmail {
                //     try await MessageAPI.shared.sendMessage(
                //         from: userEmail,
                //         to: recipientEmails,
                //         content: trimmedMessage
                //     )
                // }
            } catch {
                print("Failed to send message: \(error)")
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }
    
    @MainActor
    private func findOrCreateConversation(with emails: [String]) async throws -> Conversation {
        let userEmail = session.userEmail
        return try await viewContext.perform {
            // Try to find existing conversation with exact participants
            let request: NSFetchRequest<Conversation> = Conversation.fetchRequest()
            let conversations = try viewContext.fetch(request)
            
            // Check for matching conversation
            for conversation in conversations {
                let participants = conversation.participantsArray
                if Set(participants) == Set(emails) {
                    return conversation
                }
            }
            
            // Create new conversation
            let conversation = Conversation(context: viewContext)
            conversation.id = UUID()
            conversation.keyHash = emails.sorted().joined(separator: ",").data(using: .utf8)?.base64EncodedString() ?? ""
            conversation.conversationType = emails.count > 1 ? .group : .oneToOne
            conversation.displayName = emails.count == 1 ? emails.first : "Group Conversation"
            conversation.lastMessageDate = Date()
            conversation.hidden = false
            conversation.pinned = false
            conversation.muted = false
            conversation.hasInbox = false
            conversation.inboxUnreadCount = 0
            
            // Create participants
            for email in emails {
                let participant = ConversationParticipant(context: viewContext)
                participant.id = UUID()
                participant.participantRole = email == userEmail ? .me : .normal
                
                // Find or create person
                let personRequest: NSFetchRequest<Person> = Person.fetchRequest()
                personRequest.predicate = NSPredicate(format: "email == %@", email)
                let existingPerson = try? viewContext.fetch(personRequest).first
                
                if let person = existingPerson {
                    participant.person = person
                } else {
                    let newPerson = Person(context: viewContext)
                    newPerson.id = UUID()
                    newPerson.email = email
                    newPerson.displayName = email
                    participant.person = newPerson
                }
                
                participant.conversation = conversation
            }
            
            try viewContext.save()
            return conversation
        }
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