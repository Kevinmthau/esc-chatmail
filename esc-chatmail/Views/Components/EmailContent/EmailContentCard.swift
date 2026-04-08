import SwiftUI

enum EmailPreviewCardStyle {
    static let cornerRadius: CGFloat = 16
}

extension View {
    func emailPreviewCardChrome() -> some View {
        modifier(EmailPreviewCardChromeModifier())
    }
}

private struct EmailPreviewCardChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: EmailPreviewCardStyle.cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: EmailPreviewCardStyle.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: EmailPreviewCardStyle.cornerRadius, style: .continuous))
    }
}

/// Placeholder shown while loading email content
struct EmailContentPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image placeholder
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .frame(height: 100)

            // Text placeholders
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 16)
                    .frame(maxWidth: 200)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 12)
                    .frame(maxWidth: 160)
            }
            .padding(12)
        }
        .emailPreviewCardChrome()
    }
}

/// Fallback view when no content could be extracted
struct EmailContentFallback: View {
    let subject: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.fill")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Open original email")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)

                    Text("Preview unavailable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .emailPreviewCardChrome()
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let subject, !subject.isEmpty {
            return "Open original email: \(subject)"
        }

        return "Open original email"
    }
}
