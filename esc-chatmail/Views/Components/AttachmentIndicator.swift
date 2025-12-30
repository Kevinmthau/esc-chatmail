import SwiftUI

// MARK: - Attachment Indicator
struct AttachmentIndicator: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.caption)
            Text("\(count) attachment\(count == 1 ? "" : "s")")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
    }
}
