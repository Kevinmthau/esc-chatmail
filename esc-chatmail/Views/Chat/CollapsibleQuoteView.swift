import SwiftUI

/// A collapsible view for displaying quoted email content
struct CollapsibleQuoteView: View {
    let quotedParts: [QuotedPart]
    let isFromMe: Bool

    @State private var isExpanded = false

    var body: some View {
        if !quotedParts.isEmpty {
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                toggleButton

                if isExpanded {
                    quotedContentView
                }
            }
        }
    }

    private var toggleButton: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                Text(buttonText)
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var buttonText: String {
        let count = quotedParts.count
        if isExpanded {
            return "Hide quoted text"
        } else if count == 1 {
            return "Show quoted text"
        } else {
            return "Show \(count) quoted messages"
        }
    }

    private var quotedContentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(quotedParts.enumerated()), id: \.offset) { _, part in
                QuotedPartView(part: part)
            }
        }
        .padding(.top, 4)
    }
}

/// Displays a single quoted part with optional attribution
private struct QuotedPartView: View {
    let part: QuotedPart

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let attribution = part.attribution {
                Text(attribution)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .italic()
            }

            HStack(spacing: 0) {
                // Quote indicator bar (like in email clients)
                Rectangle()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 2)
                    .padding(.trailing, 8)

                Text(part.text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(part.nestingLevel * 8))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }
}

#Preview {
    VStack(spacing: 20) {
        CollapsibleQuoteView(
            quotedParts: [
                QuotedPart(
                    text: "This is the original message that was quoted.",
                    attribution: "On Jan 15, 2024, John Smith wrote:",
                    nestingLevel: 0
                )
            ],
            isFromMe: false
        )

        CollapsibleQuoteView(
            quotedParts: [
                QuotedPart(
                    text: "First quoted message.",
                    attribution: "On Jan 15, 2024, Alice wrote:",
                    nestingLevel: 0
                ),
                QuotedPart(
                    text: "Original message in thread.",
                    attribution: "On Jan 14, 2024, Bob wrote:",
                    nestingLevel: 1
                )
            ],
            isFromMe: true
        )
    }
    .padding()
}
