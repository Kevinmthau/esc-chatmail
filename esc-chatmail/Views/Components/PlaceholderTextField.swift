import SwiftUI

/// Text input field with placeholder overlay
/// Provides a chat-style message input with expandable height
struct PlaceholderTextField: View {
    @Binding var text: String
    let placeholder: String
    var lineLimit: ClosedRange<Int> = 1...5
    var cornerRadius: CGFloat = 18
    var backgroundColor: Color = Color(.systemGray6)
    var textFont: Font = .body
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8
    var minHeight: CGFloat? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(Color(.placeholderText))
                    .font(textFont)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
            }

            TextField("", text: $text, axis: .vertical)
                .font(textFont)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .lineLimit(lineLimit)
        }
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .frame(minHeight: minHeight)
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
