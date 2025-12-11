import SwiftUI
import Contacts

/// Legacy recipient input view with horizontal scrolling layout
/// Note: Consider using ComposeRecipientField from ComposeView.swift for new code
struct RecipientInputView: View {
    @Binding var recipients: [Recipient]
    @Binding var query: String
    @Binding var isSearching: Bool
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("To:")
                .foregroundColor(Color(.secondaryLabel))
                .padding(.leading, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(recipients) { recipient in
                        MessageRecipientChip(
                            recipient: recipient,
                            onDelete: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    recipients.removeAll { $0.id == recipient.id }
                                }
                            }
                        )
                    }

                    TextField("Add recipient", text: $query)
                        .focused(isFocused)
                        .frame(minWidth: 150)
                        .font(.system(size: 17))
                        .onChange(of: query) { _, newValue in
                            isSearching = !newValue.isEmpty
                        }
                        .onSubmit { }
                        .submitLabel(.done)
                }
                .padding(.vertical, 8)
            }
            .padding(.trailing, 16)
        }
        .frame(minHeight: 44)
        .background(Color(.systemBackground))
    }
}

/// Chip view for MessageRecipientChip (blue style)
struct MessageRecipientChip: View {
    let recipient: Recipient
    let onDelete: () -> Void

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 4) {
            Text(recipient.display)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .lineLimit(1)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.blue)
        .clipShape(Capsule())
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = false
                }
            }
        }
    }
}
