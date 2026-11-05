import SwiftUI

/// The conversation list's first row while sync is held back by a full disk
/// (`SyncEngine.isBlockedByInsufficientStorage`). Before it, a full disk showed nothing at all:
/// mail just stopped arriving while sync failed every minute in the background.
///
/// Try Again runs a user-initiated sync, which the engine still admits only if there is room
/// (`SyncStorageBackoff`). Freeing space is enough on its own: the next periodic run starts.
struct InsufficientStorageBanner: View {
    let onTryAgain: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("iPhone Storage Is Full")
                    .font(.subheadline.weight(.semibold))
                Text("New mail can't sync until you free up space. Sync resumes on its own once there's room.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onTryAgain)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
