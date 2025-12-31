import SwiftUI

/// Recipient input section with chips, text input, and autocomplete
/// Extracted from ComposeView for better separation of concerns
struct RecipientInputSection: View {
    @ObservedObject var viewModel: ComposeViewModel
    var focusedField: FocusState<ComposeView.FocusField?>.Binding
    @Binding var recipientRowHeight: CGFloat
    let showSubjectField: Bool

    var body: some View {
        recipientInputRow
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
                        .focused(focusedField, equals: .recipient)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .frame(minWidth: 120)
                        .onSubmit {
                            viewModel.addRecipientFromInput()
                            if showSubjectField {
                                focusedField.wrappedValue = .subject
                            } else {
                                focusedField.wrappedValue = .body
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
            focusedField.wrappedValue = .recipient
        }
    }

    // MARK: - Autocomplete Overlay

    @ViewBuilder
    var autocompleteOverlay: some View {
        if viewModel.showAutocomplete && !viewModel.autocompleteContacts.isEmpty {
            VStack(spacing: 0) {
                Color.clear.frame(height: recipientRowHeight)
                autocompleteList
            }
        }
    }

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
}
