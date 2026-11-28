import SwiftUI

struct ForwardedMessageCard: View {
    let content: ForwardedMessageDisplayContent
    let subjectFallback: String?
    let isFromMe: Bool
    @Environment(\.emailPreviewCardMetrics) private var metrics
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let senderLine {
                    Text(senderLine)
                        .font(metrics.font(\.subtitleSize, .semibold))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let timestamp = content.timestampText {
                    Text(timestamp)
                        .font(metrics.font(\.labelSize, .medium))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }

            if let subjectLine {
                Text(subjectLine)
                    .font(metrics.font(\.detailSize, .medium))
                    .foregroundStyle(primaryTextColor.opacity(isFromMe ? 0.92 : 0.95))
                    .lineLimit(2)
            }

            if let recipientLine = content.recipientSummary {
                Text("To: \(recipientLine)")
                    .font(metrics.font(\.labelSize, .medium))
                    .foregroundStyle(tertiaryTextColor)
                    .lineLimit(1)
            }

            if let previewLine = content.previewSnippet {
                Text(previewLine)
                    .font(metrics.font(\.detailSize))
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
                .font(metrics.font(\.labelSize, .semibold))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    /// The card's colors for its bubble and the person's contrast setting
    /// (`ForwardedMessageCardPalette`).
    private var palette: ForwardedMessageCardPalette {
        ForwardedMessageCardPalette.palette(isFromMe: isFromMe, contrast: colorSchemeContrast)
    }

    private var primaryTextColor: Color {
        palette.primaryText
    }

    private var secondaryTextColor: Color {
        palette.secondaryText
    }

    private var tertiaryTextColor: Color {
        palette.tertiaryText
    }

    private var cardBackgroundColor: Color {
        palette.cardBackground
    }

    private var strokeColor: Color {
        palette.stroke
    }
}
