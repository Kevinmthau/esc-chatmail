import SwiftUI

/// Displays message metadata: unread indicator and timestamp.
struct MessageMetadata: View {
    let date: Date
    let isUnread: Bool
    var showUnreadIndicator: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if showUnreadIndicator && isUnread {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 6, height: 6)
            }

            Text(TimestampFormatter.format(date))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
