import SwiftUI
import Contacts

struct RecipientInputView: View {
    @Binding var recipients: [RecipientToken]
    @Binding var query: String
    @Binding var isSearching: Bool
    @FocusState var focusedField: NewMessageView.Field?
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // "To:" label
            Text("To:")
                .foregroundColor(Color(.secondaryLabel))
                .padding(.leading, 16)
            
            // Scrollable area for chips and input
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Recipient chips
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
                    
                    // Input field
                    TextField("Add recipient", text: $query)
                        .focused($focusedField, equals: .recipients)
                        .frame(minWidth: 150)
                        .font(.system(size: 17))
                        .onChange(of: query) { _, newValue in
                            isSearching = !newValue.isEmpty
                        }
                        .onSubmit {
                            // Handle return key if needed
                        }
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

struct MessageRecipientChip: View {
    let recipient: RecipientToken
    let onDelete: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        HStack(spacing: 4) {
            Text(recipient.name.isEmpty ? recipient.email : recipient.name)
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