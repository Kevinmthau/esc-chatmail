import SwiftUI

/// Lightweight preview for context menu - avoids triggering expensive loads
struct MessageContextMenuPreview: View {
    let message: Message

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
            if let subject = message.subject, !subject.isEmpty {
                Text(subject)
                    .font(.footnote)
                    .fontWeight(.semibold)
            }

            // Use cleanedSnippet which is already loaded, avoid relationship traversal
            Text(message.cleanedSnippet ?? message.snippet ?? "")
                .font(.body)
                .lineLimit(10)

            Text(message.internalDate, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(message.isFromMe ? Color.blue : Color(.systemGray5))
        .foregroundColor(message.isFromMe ? .white : .primary)
        .cornerRadius(16)
        .frame(maxWidth: 280)
    }
}
