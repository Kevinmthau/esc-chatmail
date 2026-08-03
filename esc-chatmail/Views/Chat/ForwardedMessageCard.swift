import SwiftUI

struct ForwardedMessageCard: View {
    let content: ForwardedMessageDisplayContent
    let subjectFallback: String?
    let isFromMe: Bool
    /// When set, the card shows the forwarded email's complete body instead
    /// of the three-line preview snippet (chat transcript presentation).
    var fullBodyText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let senderLine {
                    Text(senderLine)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let timestamp = content.timestampText {
                    Text(timestamp)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }

            if let subjectLine {
                Text(subjectLine)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(primaryTextColor.opacity(isFromMe ? 0.92 : 0.95))
                    .lineLimit(2)
            }

            if let recipientLine = content.recipientSummary {
                Text("To: \(recipientLine)")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(tertiaryTextColor)
                    .lineLimit(1)
            }

            if let fullBodyText {
                Text(fullBodyText)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(secondaryTextColor.opacity(isFromMe ? 1 : 0.92))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let previewLine = content.previewSnippet {
                Text(previewLine)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(secondaryTextColor.opacity(isFromMe ? 1 : 0.92))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 1)
        )
    }

    private var senderLine: String? {
        content.senderDisplayName ?? PersonDisplayNameResolver.fallbackSenderName()
    }

    private var subjectLine: String? {
        let subject = content.subject ?? subjectFallback
        guard let subject, !subject.isEmpty else {
            return nil
        }
        return subject
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondaryTextColor)

            Text("Forwarded message")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var primaryTextColor: Color {
        isFromMe ? .white : .primary
    }

    private var secondaryTextColor: Color {
        isFromMe ? Color.white.opacity(0.82) : Color.secondary
    }

    private var tertiaryTextColor: Color {
        isFromMe ? Color.white.opacity(0.66) : Color.secondary.opacity(0.84)
    }

    private var cardBackgroundColor: Color {
        isFromMe ? Color.white.opacity(0.14) : Color(.systemBackground).opacity(0.68)
    }

    private var strokeColor: Color {
        isFromMe ? Color.white.opacity(0.12) : Color.primary.opacity(0.08)
    }
}
