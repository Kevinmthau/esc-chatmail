import SwiftUI

struct SharedDocumentLinkCard: View {
    let link: SharedDocumentLink
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(link.url)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconColor.opacity(0.16))

                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                .frame(width: 40, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(link.kind.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(link.hostDisplay)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Text(link.url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.blue)
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(link.kind.title)")
    }

    private var iconName: String {
        switch link.kind {
        case .googleSheet:
            return "tablecells"
        case .googleDoc:
            return "doc.text"
        case .googleSlides:
            return "rectangle.on.rectangle"
        case .googleDriveFile:
            return "doc.badge.gearshape"
        case .googleDriveFolder:
            return "folder"
        }
    }

    private var iconColor: Color {
        switch link.kind {
        case .googleSheet:
            return .green
        case .googleDoc:
            return .blue
        case .googleSlides:
            return .orange
        case .googleDriveFile:
            return .indigo
        case .googleDriveFolder:
            return .teal
        }
    }
}
