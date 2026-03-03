import SwiftUI

/// Animated line-fill indicator shown while an outgoing message is still uploading attachments.
struct MessageSendingIndicator: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))

                    Capsule()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: max(geometry.size.width * progress, 2))
                }
            }
            .frame(width: 84, height: 3)

            Text("Sending")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            progress = 0
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                progress = 1
            }
        }
        .onDisappear {
            progress = 0
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sending")
    }
}
