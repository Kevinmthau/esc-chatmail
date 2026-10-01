import SwiftUI

/// Circular send button with loading state
/// Used by ComposeView and ChatReplyBar for message sending
struct SendButton: View {
    let isEnabled: Bool
    let isSending: Bool
    /// ComposeView keeps the spinner: its composer owns the content until
    /// transmission admission. The chat reply bar passes false because its
    /// optimistic bubble already shows progress.
    var showsProgress = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isEnabled ? Color.accentColor : Color(.systemGray3))
                    .frame(width: 32, height: 32)

                if isSending && showsProgress {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.callout.weight(.bold))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
}

#Preview {
    HStack(spacing: 20) {
        SendButton(isEnabled: true, isSending: false) { }
        SendButton(isEnabled: false, isSending: false) { }
        SendButton(isEnabled: true, isSending: true) { }
    }
    .padding()
}
