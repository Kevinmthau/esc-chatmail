import SwiftUI
import CoreData
import Contacts

/// Unified message composition view
/// Consolidates NewMessageComposerView and NewMessageView
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: ComposeViewModel
    @FocusState private var focusedField: FocusField?

    @State private var recipientRowHeight: CGFloat = 44
    @State private var showingContactPicker = false
    @State private var iMessageHeaderHeight: CGFloat = 0

    private let presentationStyle: PresentationStyle
    private let onOpenConversation: ((Conversation) -> Void)?
    private let onSendConversation: ((NSManagedObjectID) -> Void)?

    private var iMessageCanvasColor: Color {
        Color(uiColor: UIColor(red: 239/255, green: 239/255, blue: 244/255, alpha: 1))
    }

    enum FocusField {
        case recipient
        case subject
        case body
    }

    enum PresentationStyle {
        case standard
        case iMessage
    }

    private var usesIMessagePresentation: Bool {
        presentationStyle == .iMessage && viewModel.mode == .newMessage
    }

    private var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TEST_MODE")
    }

    private var shouldOpenExistingConversationOnSelection: Bool {
        usesIMessagePresentation && onOpenConversation != nil
    }

    @MainActor
    init(
        mode: ComposeViewModel.Mode = .newMessage,
        presentationStyle: PresentationStyle = .standard,
        deps: Dependencies? = nil,
        onOpenConversation: ((Conversation) -> Void)? = nil,
        onSendConversation: ((NSManagedObjectID) -> Void)? = nil
    ) {
        let resolvedDeps = deps ?? Dependencies.shared
        self.presentationStyle = presentationStyle
        self.onOpenConversation = onOpenConversation
        self.onSendConversation = onSendConversation
        _viewModel = StateObject(wrappedValue: ComposeViewModel(mode: mode, deps: resolvedDeps))
    }

    private var recipientSection: RecipientInputSection {
        RecipientInputSection(
            viewModel: viewModel,
            focusedField: $focusedField,
            recipientRowHeight: $recipientRowHeight,
            showSubjectField: viewModel.showSubjectField,
            style: usesIMessagePresentation ? .iMessage : .standard,
            autocompleteTopInset: usesIMessagePresentation ? iMessageHeaderHeight : 0,
            onSelectContact: { contact, selectedEmail in
                let email = selectedEmail ?? contact.primaryEmail
                handleSelectedRecipient(email: email, displayName: contact.displayName)
            },
            onContactButtonTapped: usesIMessagePresentation ? {
                showingContactPicker = true
            } : nil
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // Main content
                VStack(spacing: 0) {
                    if usesIMessagePresentation {
                        iMessageHeader
                    }

                    recipientSection.body

                    if !usesIMessagePresentation {
                        Divider()
                    }

                    if viewModel.showSubjectField {
                        subjectSection
                        Divider()
                    }

                    bodySection

                    Spacer(minLength: 0)

                    if !viewModel.showSubjectField {
                        ComposeInputBar(
                            viewModel: viewModel,
                            focusedField: $focusedField,
                            onSendSuccess: { handleSendSuccess() },
                            style: usesIMessagePresentation ? .iMessage : .standard
                        )
                    }
                }
                .background(
                    usesIMessagePresentation ? iMessageCanvasColor : Color(.systemBackground)
                )

                // Autocomplete overlay - positioned below recipient row
                recipientSection.autocompleteOverlay
            }
            .accessibilityIdentifier("ComposeViewRoot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !usesIMessagePresentation {
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
                        Button("Send") {
                            Task {
                                if await viewModel.send() {
                                    handleSendSuccess()
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
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerView(
                onContactSelected: { contact in
                    handleContactPickerSelection(contact)
                },
                onCancel: { }
            )
        }
        .task {
            guard !isRunningUITests else { return }
            await viewModel.requestContactsAccess()
        }
        .onAppear {
            // Setup mode-specific data (forward text, reply recipients, etc.)
            viewModel.setupForMode()

            // Auto-focus recipient field after a brief delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                guard !Task.isCancelled else { return }
                focusedField = .recipient
            }
        }
    }

    @ViewBuilder
    private var iMessageHeader: some View {
        ZStack {
            Text("New Message")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityIdentifier("ComposeTitleText")

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .fill(Color(uiColor: UIColor(red: 226/255, green: 226/255, blue: 232/255, alpha: 1))
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("ComposeCloseButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        iMessageHeaderHeight = geo.size.height
                    }
                    .onChange(of: geo.size.height) { _, newValue in
                        iMessageHeaderHeight = newValue
                    }
            }
        )
    }

    private func handleContactPickerSelection(_ contact: CNContact) {
        guard let email = contact.emailAddresses.first?.value as String? else { return }
        let displayName = formattedName(for: contact)
        handleSelectedRecipient(email: email, displayName: displayName)
    }

    private func handleSendSuccess() {
        if let conversationObjectID = viewModel.lastSentConversationObjectID {
            onSendConversation?(conversationObjectID)
        }
        dismiss()
    }

    private func formattedName(for contact: CNContact) -> String? {
        let displayName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? nil : displayName
    }

    private func handleSelectedRecipient(email: String, displayName: String?) {
        let prospectiveRecipients = viewModel.recipients.map(\.email) + [email]

        if shouldOpenExistingConversationOnSelection,
           let existingConversation = viewModel.findActiveConversation(forRecipients: prospectiveRecipients) {
            viewModel.clearAutocomplete()
            viewModel.recipientInput = ""
            onOpenConversation?(existingConversation)
            dismiss()
            return
        }

        viewModel.addRecipient(email: email, displayName: displayName)
        viewModel.recipientInput = ""
        viewModel.clearAutocomplete()
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
            VStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.body)
                        .focused($focusedField, equals: .body)
                        .padding(.horizontal, 8)
                        .frame(minHeight: viewModel.isForwardMode ? 120 : nil)

                    if viewModel.body.isEmpty {
                        Text(viewModel.isForwardMode ? "Add a message (optional)" : "Message")
                            .foregroundColor(.gray.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

                if viewModel.isForwardMode {
                    forwardPreviewSection
                }
            }
        }
    }

    @ViewBuilder
    private var forwardPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Forwarded message")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            if let html = viewModel.forwardedPreviewHTML {
                BaseEmailWebView(htmlContent: html, mode: .simplePreview)
                    .frame(height: 240)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    Text(viewModel.forwardedPreviewText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 160)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }
        }
    }

}

// MARK: - Preview

#Preview {
    ComposeView(mode: .newMessage)
}
