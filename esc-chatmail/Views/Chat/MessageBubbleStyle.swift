import SwiftUI

/// Configuration for message bubble display style.
enum MessageBubbleStyle {
    /// Full-featured style with avatars, sender names, and rich content
    case standard
    /// Compact style with minimal UI for performance
    case compact

    // MARK: - Display Options

    var showAvatar: Bool {
        switch self {
        case .standard: return true
        case .compact: return false
        }
    }

    var showSenderName: Bool {
        switch self {
        case .standard: return true
        case .compact: return true
        }
    }

    var showUnreadIndicator: Bool {
        switch self {
        case .standard: return true
        case .compact: return false
        }
    }

    var showAttachmentGrid: Bool {
        switch self {
        case .standard: return true
        case .compact: return false
        }
    }

    var textLineLimit: Int? {
        switch self {
        case .standard: return 15
        case .compact: return 3
        }
    }

    var maxBubbleWidth: CGFloat {
        switch self {
        case .standard: return 280
        case .compact: return UIScreen.main.bounds.width * 0.75
        }
    }

    // MARK: - Styling

    var bubbleCornerRadius: CGFloat {
        switch self {
        case .standard: return 12
        case .compact: return 16
        }
    }

    var bubblePadding: EdgeInsets {
        switch self {
        case .standard:
            return EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        case .compact:
            return EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        }
    }

    func senderBubbleColor() -> Color {
        .blue
    }

    func recipientBubbleColor() -> Color {
        switch self {
        case .standard:
            return Color.gray.opacity(0.2)
        case .compact:
            return Color(.systemGray5)
        }
    }

    func bubbleBackground(isFromMe: Bool) -> Color {
        isFromMe ? senderBubbleColor() : recipientBubbleColor()
    }

    func textColor(isFromMe: Bool) -> Color {
        isFromMe ? .white : .primary
    }
}
