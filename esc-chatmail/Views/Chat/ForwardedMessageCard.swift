import SwiftUI

struct ForwardedMessageCard: View {
    let content: ForwardedMessageDisplayContent
    let subjectFallback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let senderLine {
                    Text(senderLine)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let timestamp = content.timestampText {
                    Text(timestamp)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            if let subjectLine {
                Text(subjectLine)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
            }

            if let recipientLine = content.recipientSummary {
                Text("To: \(recipientLine)")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }

            if let previewLine = content.previewSnippet {
                Text(previewLine)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
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
                .foregroundStyle(.white.opacity(0.84))

            Text("Forwarded message")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}
