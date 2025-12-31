import SwiftUI

/// Text input field with placeholder overlay
/// Provides a chat-style message input with expandable height
struct PlaceholderTextField: View {
    @Binding var text: String
    let placeholder: String
    var lineLimit: ClosedRange<Int> = 1...5
    var cornerRadius: CGFloat = 18

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(Color(.placeholderText))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            TextField("", text: $text, axis: .vertical)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .lineLimit(lineLimit)
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

#Preview {
    VStack(spacing: 20) {
        PlaceholderTextField(text: .constant(""), placeholder: "iMessage")
        PlaceholderTextField(text: .constant("Hello world"), placeholder: "iMessage")
        PlaceholderTextField(
            text: .constant("A longer message that\nspans multiple lines"),
            placeholder: "iMessage"
        )
    }
    .padding()
}
