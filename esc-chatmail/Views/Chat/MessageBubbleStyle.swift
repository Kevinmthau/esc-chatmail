import SwiftUI

/// Configuration for message bubble display style.
enum MessageBubbleStyle {
    /// Full-featured style with avatars, sender names, and rich content
    case standard
    /// Compact style with minimal UI for performance
    case compact
    /// Messages' transcript on the Mac (`docs/mac-imessage-ui-plan.md`, PR 4): tailed bubbles
    /// that take a share of the transcript's width, runs of one sender's bubbles set close
    /// together, a centered time line between groups of messages where the other styles put a
    /// timestamp under every bubble, and no avatar in a one-to-one chat. The chat's presenter
    /// names the style (`ChatView.bubbleStyle`), so no view checks the platform.
    case mac

    // MARK: - Display Options

    var showAvatar: Bool {
        switch self {
        case .standard: return true
        case .compact: return false
        case .mac: return true
        }
    }

    var showSenderName: Bool {
        switch self {
        case .standard: return true
        case .compact: return true
        case .mac: return true
        }
    }

    var showUnreadIndicator: Bool {
        switch self {
        case .standard: return true
        case .compact: return false
        case .mac: return false
        }
    }

    var showAttachmentGrid: Bool {
        switch self {
        case .standard: return true
        case .compact: return false
        case .mac: return true
        }
    }

    var textLineLimit: Int? {
        switch self {
        case .standard: return nil
        case .compact: return 3
        case .mac: return nil
        }
    }

    /// The widest a bubble's column is where its width does not follow the transcript's, and the
    /// width of a preview card or a shared-document card in every style: preview sizing must
    /// stay predictable (AGENTS.md), so on the Mac only text follows the window
    /// (`textBubbleMaxWidth(transcriptWidth:)`).
    ///
    /// Main-actor isolated because `.compact` reads the screen width (`PlatformScreen`); every
    /// caller is a view.
    @MainActor
    var maxBubbleWidth: CGFloat {
        switch self {
        case .standard: return 280
        case .compact: return min(PlatformScreen.width * 0.75, 320)
        case .mac: return 280
        }
    }

    // MARK: - Styling

    var bubbleCornerRadius: CGFloat {
        switch self {
        case .standard: return 12
        case .compact: return 16
        case .mac: return 17
        }
    }

    var bubblePadding: EdgeInsets {
        switch self {
        case .standard:
            return EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        case .compact:
            return EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        case .mac:
            return EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
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
            return Color.systemGray5
        case .mac:
            // Opaque: the Mac's transcript is a white pane, and a tail drawn in a
            // translucent gray would show darker where it overlaps its bubble.
            return Color.systemGray5
        }
    }

    func bubbleBackground(isFromMe: Bool) -> Color {
        isFromMe ? senderBubbleColor() : recipientBubbleColor()
    }

    func textColor(isFromMe: Bool) -> Color {
        isFromMe ? .white : .primary
    }

    // MARK: - Transcript layout

    /// The share of the transcript's width a text bubble may take, or nil where its width is
    /// `maxBubbleWidth` whatever the transcript's is. A first reading of a screenshot of
    /// Messages on macOS 26, not a measurement.
    var textBubbleWidthShare: CGFloat? {
        switch self {
        case .standard, .compact: return nil
        case .mac: return 0.65
        }
    }

    /// The widest a text bubble's column is in a transcript of the given width. On the Mac it
    /// follows the window, so text reflows when the window is resized, and it is never
    /// narrower than `maxBubbleWidth`: in a narrow chat column the share alone would wrap text
    /// in less room than the cards beside it get.
    @MainActor
    func textBubbleMaxWidth(transcriptWidth: CGFloat) -> CGFloat {
        guard let share = textBubbleWidthShare, transcriptWidth.isFinite, transcriptWidth > 0 else {
            return maxBubbleWidth
        }
        return max(maxBubbleWidth, (transcriptWidth * share).rounded(.down))
    }

    /// The cap the text itself takes inside the row's column, or nil where the column's cap is
    /// the text's. The column is as wide as the widest thing it can hold, and on the Mac that
    /// is an image (`imageMaxWidth`) wherever the text's share of the transcript is less: with
    /// no cap of its own, text in a chat column under about 615 points wrapped at the image's
    /// 400 points, not at its share.
    @MainActor
    func textContentMaxWidth(transcriptWidth: CGFloat) -> CGFloat? {
        guard textBubbleWidthShare != nil else { return nil }
        return textBubbleMaxWidth(transcriptWidth: transcriptWidth)
    }

    /// The widest an image attachment draws where the transcript has room for it, or nil for
    /// `ImageAttachmentBubble`'s own cap. Fixed, not a share of the window: a frame that
    /// followed the window would change the height of every image row on a resize. What a
    /// row actually gets is `imageMaxWidth(transcriptWidth:)`.
    var imageMaxWidth: CGFloat? {
        switch self {
        case .standard, .compact: return nil
        case .mac: return 400
        }
    }

    /// What a row with an image keeps beside it, of the transcript's width: the stack's
    /// padding on both sides (32), the avatar and its gap in a group (32), the tail's room
    /// (4), and the gap and the spacer that push the row to its side (16), rounded up. Added
    /// from the views' own numbers, not measured.
    static let imageRowChromeWidth: CGFloat = 96

    /// An image is never asked to be narrower than this, however narrow the transcript.
    static let minimumImageMaxWidth: CGFloat = 120

    /// The widest an image attachment draws in a transcript of the given width, or nil for
    /// `ImageAttachmentBubble`'s own cap. It is `imageMaxWidth` wherever that fits, which is
    /// every chat column from 496 points up. Below that it is what the column has left: the
    /// window's minimum is 700 points and the sidebar takes 260 to 480 of them, so the chat
    /// column can be 220 points wide, and a row holding a 400-point image was wider than the
    /// transcript and was cut off at both edges. In so narrow a column an image row's height
    /// does follow the window, as a text row's does everywhere.
    func imageMaxWidth(transcriptWidth: CGFloat) -> CGFloat? {
        guard let cap = imageMaxWidth else { return nil }
        // Before the transcript has a width.
        guard transcriptWidth.isFinite, transcriptWidth > 0 else { return cap }
        let room = (transcriptWidth - Self.imageRowChromeWidth).rounded(.down)
        return min(cap, max(Self.minimumImageMaxWidth, room))
    }

    /// How far a bubble's tail reaches past the bubble's edge, or 0 for a style whose bubbles
    /// have none. Every row keeps this much free on the tail's side, whether or not its bubble
    /// draws a tail, so the bubbles of a run line up.
    var bubbleTailWidth: CGFloat {
        switch self {
        case .standard, .compact: return 0
        case .mac: return 4
        }
    }

    /// Between two rows of the transcript. One constant for the whole stack; what separates
    /// one run of bubbles from the next is padding inside the row that starts the run
    /// (`runTopPadding`).
    var rowSpacing: CGFloat {
        switch self {
        case .standard, .compact: return 8
        case .mac: return 2
        }
    }

    /// Added above the first row of a run, on top of `rowSpacing`.
    var runTopPadding: CGFloat {
        switch self {
        case .standard, .compact: return 0
        case .mac: return 8
        }
    }

    /// Whether a row carries its own timestamp (and unread dot) under its bubble. Where it
    /// does not, the time is a centered line between groups of messages
    /// (`showsTimestampSeparators`) and a tooltip on the bubble.
    var showsTimestampUnderBubble: Bool {
        switch self {
        case .standard, .compact: return true
        case .mac: return false
        }
    }

    /// Whether a centered time line is drawn above a row that starts a new day or follows a
    /// long gap (`ChatTimestampSeparatorPolicy`). Such a style reads the row before each row,
    /// which the others never fetch.
    var showsTimestampSeparators: Bool {
        switch self {
        case .standard, .compact: return false
        case .mac: return true
        }
    }

    /// Whether a message of a few emoji and nothing else is drawn large, without a bubble
    /// (`ChatLargeEmojiPolicy`).
    var drawsLargeEmoji: Bool {
        switch self {
        case .standard, .compact: return false
        case .mac: return true
        }
    }

    /// The font of a message drawn as large emoji.
    var largeEmojiFont: Font {
        .system(size: 40)
    }
}
