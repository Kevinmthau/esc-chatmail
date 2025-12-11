import SwiftUI
import CoreData

/// @deprecated Use ComposeView instead
/// This view is kept for backwards compatibility during migration
struct NewMessageComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    
    @StateObject private var contactsService = ContactsService()
    @State private var recipients: [Recipient] = []
    @State private var recipientInput = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var autocompleteContacts: [ContactsService.ContactMatch] = []
    @State private var showAutocomplete = false
    @FocusState private var recipientFieldFocused: Bool
    @FocusState private var bodyFieldFocused: Bool
    
    private let sendService: GmailSendService
    
    init() {
        self.sendService = GmailSendService(
            viewContext: CoreDataStack.shared.viewContext
        )
    }
    
    var canSend: Bool {
        !recipients.isEmpty &&
        recipients.allSatisfy { $0.isValid } &&
        !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                recipientSection
                
                Divider()
                
                subjectSection
                
                Divider()
                
                bodySection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Send") {
                        Task {
                            await sendMessage()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSend || isSending)
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "Failed to send message")
        }
        .task {
            await requestContactsAccess()
        }
    }
    
    @ViewBuilder
    private var recipientSection: some View {
        ZStack(alignment: .topLeading) {
            RecipientField(
                recipients: $recipients,
                inputText: $recipientInput,
                isFocused: $recipientFieldFocused,
                onSubmit: {
                    bodyFieldFocused = true
                },
                onTextChange: { text in
                    Task {
                        await searchContacts(query: text)
                    }
                }
            )
            .frame(minHeight: 44)
            
            if showAutocomplete && !autocompleteContacts.isEmpty {
                AutocompleteList(
                    contacts: autocompleteContacts,
                    onSelect: { email, displayName in
                        addRecipient(email: email, displayName: displayName)
                        recipientInput = ""
                        showAutocomplete = false
                        autocompleteContacts = []
                    },
                    onDismiss: {
                        showAutocomplete = false
                    }
                )
                .offset(y: 50)
                .zIndex(1)
            }
        }
    }
    
    @ViewBuilder
    private var subjectSection: some View {
        HStack {
            Text("Subject:")
                .foregroundColor(.gray)
                .padding(.leading, 16)
            
            TextField("", text: $subject)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.trailing, 16)
        }
        .frame(height: 44)
    }
    
    @ViewBuilder
    private var bodySection: some View {
        TextEditor(text: $messageBody)
            .focused($bodyFieldFocused)
            .padding(.horizontal, 8)
            .overlay(
                Group {
                    if messageBody.isEmpty {
                        Text("iMessage")
                            .foregroundColor(.gray.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                },
                alignment: .topLeading
            )
    }
    
    private func requestContactsAccess() async {
        if contactsService.authorizationStatus == .notDetermined {
            _ = await contactsService.requestAccess()
        }
    }
    
    private func searchContacts(query: String) async {
        guard !query.isEmpty else {
            await MainActor.run {
                autocompleteContacts = []
                showAutocomplete = false
            }
            return
        }
        
        let matches = await contactsService.searchContacts(query: query)
        
        await MainActor.run {
            autocompleteContacts = matches
            showAutocomplete = !matches.isEmpty
        }
    }
    
    private func addRecipient(email: String, displayName: String?) {
        let recipient = Recipient(email: email, displayName: displayName)
        if !recipients.contains(where: { $0.email == recipient.email }) {
            recipients.append(recipient)
        }
    }
    
    private func sendMessage() async {
        guard canSend else { return }
        
        await MainActor.run {
            isSending = true
        }
        
        let recipientEmails = recipients.map { $0.email }
        let body = messageBody
        let messageSubject = subject.isEmpty ? nil : subject
        
        let optimisticMessageID = await MainActor.run {
            let message = sendService.createOptimisticMessage(
                to: recipientEmails,
                body: body,
                subject: messageSubject
            )
            return message.id
        }
        
        do {
            let result = try await sendService.sendNew(
                to: recipientEmails,
                body: body,
                subject: messageSubject,
                attachmentInfos: []
            )
            
            await MainActor.run {
                if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                    sendService.updateOptimisticMessage(optimisticMessage, with: result)
                }
                dismiss()
            }
            
            // Trigger sync to fetch the sent message from Gmail
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