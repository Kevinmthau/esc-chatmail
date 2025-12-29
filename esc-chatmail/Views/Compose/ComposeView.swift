import SwiftUI
import CoreData

/// Unified message composition view
/// Consolidates NewMessageComposerView and NewMessageView
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @StateObject private var viewModel: ComposeViewModel
    @FocusState private var focusedField: FocusField?

    @State private var showingAttachmentPicker = false
    @State private var recipientRowHeight: CGFloat = 44

    enum FocusField {
        case recipient
        case subject
        case body
    }

    init(mode: ComposeViewModel.Mode = .newMessage) {
        _viewModel = StateObject(wrappedValue: ComposeViewModel(mode: mode))
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // Main content
                VStack(spacing: 0) {
                    recipientInputRow

                    Divider()

                    if viewModel.showSubjectField {
                        subjectSection
                        Divider()
                    }

                    bodySection

                    Spacer(minLength: 0)

                    if !viewModel.showSubjectField {
                        inputBar
                    }
                }

                // Autocomplete overlay - positioned below recipient row
                if viewModel.showAutocomplete && !viewModel.autocompleteContacts.isEmpty {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: recipientRowHeight)
                        autocompleteList
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(viewModel.navigationTitle)
                        .font(.headline)
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.showSubjectField {
                        Button("Send") {
                            Task {
                                if await viewModel.send() {
                                    dismiss()
                                }
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(!viewModel.canSend)
                    }
                }
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "Failed to send message")
        }
        .sheet(isPresented: $showingAttachmentPicker) {
            AttachmentPicker(attachments: .constant([]))
        }
        .task {
            await viewModel.requestContactsAccess()
        }
        .onAppear {
            // Setup mode-specific data (forward text, reply recipients, etc.)
            viewModel.setupForMode()

            // Auto-focus recipient field after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedField = .recipient
            }
        }
    }

    // MARK: - Recipient Input Row

    @ViewBuilder
    private var recipientInputRow: some View {
        HStack(spacing: 8) {
            Text("To:")
                .foregroundColor(.secondary)
                .padding(.leading, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.recipients) { recipient in
                        RecipientChip(
                            recipient: recipient,
                            onRemove: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    viewModel.removeRecipient(recipient)
                                }
                            }
                        )
                    }

                    TextField("", text: $viewModel.recipientInput)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .recipient)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .frame(minWidth: 120)
                        .onSubmit {
                            viewModel.addRecipientFromInput()
                            if viewModel.showSubjectField {
                                focusedField = .subject
                            } else {
                                focusedField = .body
                            }
                        }
                        .onChange(of: viewModel.recipientInput) { _, newValue in
                            if newValue.hasSuffix(",") || newValue.hasSuffix(" ") {
                                let trimmed = String(newValue.dropLast())
                                if !trimmed.isEmpty {
                                    viewModel.recipientInput = trimmed
                                    viewModel.addRecipientFromInput()
                                } else {
                                    viewModel.recipientInput = ""
                                }
                            } else {
                                viewModel.searchContacts(query: newValue)
                            }
                        }
                }
                .padding(.vertical, 8)
            }
            .padding(.trailing, 16)
        }
        .frame(minHeight: 44)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    recipientRowHeight = geo.size.height
                }
                .onChange(of: geo.size.height) { _, newHeight in
                    recipientRowHeight = newHeight
                }
            }
        )
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = .recipient
        }
    }

    // MARK: - Autocomplete List

    @ViewBuilder
    private var autocompleteList: some View {
        VStack(spacing: 0) {
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.autocompleteContacts, id: \.primaryEmail) { contact in
                        Button {
                            viewModel.addRecipient(email: contact.primaryEmail, displayName: contact.displayName)
                            viewModel.recipientInput = ""
                            viewModel.clearAutocomplete()
                        } label: {
                            HStack(spacing: 12) {
                                if let imageData = contact.imageData,
                                   let uiImage = UIImage(data: imageData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 40, height: 40)
                                        .clipShape(Circle())
                                } else {
                                    contactInitialsView(for: contact)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.displayName)
                                        .font(.system(size: 16))
                                        .foregroundColor(.primary)
                                    Text(contact.primaryEmail)
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color(.systemBackground))

                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    private func contactInitialsView(for contact: ContactsService.ContactMatch) -> some View {
        ZStack {
            Circle()
                .fill(Color(.systemGray4))
                .frame(width: 40, height: 40)
            Text(contact.displayName.prefix(1).uppercased())
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
        }
    }

    // MARK: - Subject Section

    @ViewBuilder
    private var subjectSection: some View {
        HStack {
            Text("Subject:")
                .foregroundColor(.secondary)
                .padding(.leading, 16)

            TextField("", text: $viewModel.subject)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .subject)
                .padding(.trailing, 16)
                .onSubmit {
                    focusedField = .body
                }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = .subject
        }
    }

    // MARK: - Body Section

    @ViewBuilder
    private var bodySection: some View {
        if viewModel.showSubjectField {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.body)
                    .focused($focusedField, equals: .body)
                    .padding(.horizontal, 8)

                if viewModel.body.isEmpty {
                    Text("Message")
                        .foregroundColor(.gray.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Input Bar (Message Style)

    @ViewBuilder
    private var inputBar: some View {
        VStack(spacing: 0) {
            if !viewModel.attachments.isEmpty {
                attachmentStrip
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                Button(action: { showingAttachmentPicker = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                }

                messageInputField

                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private var messageInputField: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .leading) {
                if viewModel.body.isEmpty {
                    Text("iMessage")
                        .foregroundColor(Color(.placeholderText))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                TextField("", text: $viewModel.body, axis: .vertical)
                    .focused($focusedField, equals: .body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .lineLimit(1...5)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var sendButton: some View {
        Button(action: {
            Task {
                if await viewModel.send() {
                    dismiss()
                }
            }
        }) {
            ZStack {
                Circle()
                    .fill(viewModel.canSend ? Color.accentColor : Color(.systemGray3))
                    .frame(width: 32, height: 32)

                if viewModel.isSending {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.callout.weight(.bold))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(!viewModel.canSend)
        .animation(.easeInOut(duration: 0.2), value: viewModel.canSend)
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachments) { attachment in
                    ComposeAttachmentThumbnail(attachment: attachment) {
                        viewModel.removeAttachment(attachment)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.gray.opacity(0.05))
    }
}

// MARK: - Preview

#Preview {
    ComposeView(mode: .newMessage)
}
