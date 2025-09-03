import SwiftUI
import CoreData

struct NewMessageComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    
    @StateObject private var contactsService = ContactsService()
    @State private var recipients: [RecipientField.Recipient] = []
    @State private var recipientInput = ""
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
        let recipient = RecipientField.Recipient(email: email, displayName: displayName)
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
        
        let optimisticMessage = await MainActor.run {
            sendService.createOptimisticMessage(
                to: recipientEmails,
                body: body
            )
        }
        
        do {
            let result = try await sendService.sendNew(
                to: recipientEmails,
                body: body
            )
            
            await MainActor.run {
                sendService.updateOptimisticMessage(optimisticMessage, with: result)
                dismiss()
            }
            
            // Trigger sync to fetch the sent message from Gmail
            Task {
                try? await SyncEngine.shared.performIncrementalSync()
            }
        } catch {
            await MainActor.run {
                sendService.deleteOptimisticMessage(optimisticMessage)
                errorMessage = error.localizedDescription
                showError = true
                isSending = false
            }
        }
    }
}