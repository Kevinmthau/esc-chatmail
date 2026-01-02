import SwiftUI

/// A reusable button for viewing more content in message bubbles.
/// Used for "View More", "View Email", and similar actions.
struct ViewContentButton: View {
    let label: String
    let icon: String?
    let action: () -> Void

    init(label: String, icon: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Image(systemName: "arrow.up.forward")
                    .font(.caption2)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

// MARK: - Convenience Initializers

extension ViewContentButton {
    /// Creates a "View More" button for truncated content.
    static func viewMore(action: @escaping () -> Void) -> ViewContentButton {
        ViewContentButton(label: "View More", action: action)
    }

    /// Creates a "View Email" button for HTML content.
    static func viewEmail(action: @escaping () -> Void) -> ViewContentButton {
        ViewContentButton(label: "View Email", icon: "doc.richtext", action: action)
    }
}
