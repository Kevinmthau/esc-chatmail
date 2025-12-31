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

    private var recipientSection: RecipientInputSection {
        RecipientInputSection(
            viewModel: viewModel,
            focusedField: $focusedField,
            recipientRowHeight: $recipientRowHeight,
            showSubjectField: viewModel.showSubjectField
        )
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // Main content
                VStack(spacing: 0) {
                    recipientSection.body

                    Divider()

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
                            showingAttachmentPicker: $showingAttachmentPicker,
                            onSendSuccess: { dismiss() }
                        )
                    }
                }

                // Autocomplete overlay - positioned below recipient row
                recipientSection.autocompleteOverlay
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

}

// MARK: - Preview

#Preview {
    ComposeView(mode: .newMessage)
}
