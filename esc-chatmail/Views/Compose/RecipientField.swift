import SwiftUI

/// Legacy RecipientField that uses the unified Recipient model
/// Note: Consider using ComposeRecipientField from ComposeView.swift for new code
struct RecipientField: View {
    @Binding var recipients: [Recipient]
    @Binding var inputText: String
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onTextChange: (String) -> Void

    var body: some View {
        WrappingHStack(alignment: .leading, spacing: 6) {
            ForEach(recipients) { recipient in
                RecipientFieldChip(
                    recipient: recipient,
                    onRemove: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            recipients.removeAll { $0.id == recipient.id }
                        }
                    }
                )
            }

            TextField("To:", text: $inputText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .frame(minWidth: 100)
                .onSubmit {
                    addRecipientFromInput()
                    onSubmit()
                }
                .onChange(of: inputText) { _, newValue in
                    if newValue.hasSuffix(",") || newValue.hasSuffix(" ") {
                        let trimmed = String(newValue.dropLast())
                        if !trimmed.isEmpty {
                            inputText = trimmed
                            addRecipientFromInput()
                        } else {
                            inputText = ""
                        }
                    } else {
                        onTextChange(newValue)
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addRecipientFromInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if EmailValidator.isValid(trimmed) {
            let normalized = EmailNormalizer.normalize(trimmed)
            if !recipients.contains(where: { $0.email == normalized }) {
                withAnimation(.easeIn(duration: 0.2)) {
                    recipients.append(Recipient(email: trimmed))
                }
                inputText = ""
            }
        }
    }
}

/// Chip view for RecipientField
/// Uses the unified Recipient model
struct RecipientFieldChip: View {
    let recipient: Recipient
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(recipient.display)
                .font(.subheadline)
                .foregroundColor(recipient.isValid ? .primary : .red)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(recipient.isValid ? Color.gray.opacity(0.15) : Color.red.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(recipient.isValid ? Color.clear : Color.red.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
