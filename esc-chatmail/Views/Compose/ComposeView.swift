import SwiftUI
import CoreData

/// Unified message composition view
/// Consolidates NewMessageComposerView and NewMessageView
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @StateObject private var viewModel: ComposeViewModel
    @FocusState private var focusedField: FocusField?

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
        NavigationStack {
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
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "Failed to send message")
        }
        .task {
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
