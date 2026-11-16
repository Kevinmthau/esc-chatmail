import SwiftUI

/// Text input field with placeholder overlay
/// Provides a chat-style message input with expandable height
struct PlaceholderTextField: View {
    @Binding var text: String
    let placeholder: String
    var lineLimit: ClosedRange<Int> = 1...5
    var cornerRadius: CGFloat = 18
    var backgroundColor: Color = Color.systemGray6
    var textFont: Font = .body
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8
    var minHeight: CGFloat? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                // The field below is named by this word, so the word drawn here is hidden
                // from accessibility: left in, VoiceOver read it as text of its own, and then
                // a text field with no name.
                Text(placeholder)
                    .foregroundColor(Color.placeholderText)
                    .font(textFont)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .accessibilityHidden(true)
            }

            TextField("", text: $text, axis: .vertical)
                .font(textFont)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .lineLimit(lineLimit)
                .accessibilityLabel(placeholder)
        }
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .frame(minHeight: minHeight)
    }
}

#Preview {
    VStack(spacing: 20) {
        PlaceholderTextField(text: .constant(""), placeholder: MessageFieldPolicy.placeholder)
        PlaceholderTextField(text: .constant("Hello world"), placeholder: MessageFieldPolicy.placeholder)
        PlaceholderTextField(
            text: .constant("A longer message that\nspans multiple lines"),
            placeholder: MessageFieldPolicy.placeholder
        )
    }
    .padding()
}
