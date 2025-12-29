import SwiftUI

struct RecipientChip: View {
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
