import SwiftUI

/// Sizes of a To: field suggestion row, shared by the row and its divider so the divider's
/// inset stays under the name. iPhone sizes went up on Kevin's ask (2026-11-25: name and
/// address read too small at 16 and 13 points); the Mac keeps the old ones beside its
/// 13-point body text, and has no Dynamic Type to scale them.
enum AutocompleteContactRowMetrics {
    #if os(macOS)
    static let nameSize: CGFloat = 16
    static let emailSize: CGFloat = 13
    static let avatarSize: CGFloat = 40
    #else
    static let nameSize: CGFloat = 20
    static let emailSize: CGFloat = 16
    static let avatarSize: CGFloat = 44
    #endif
    /// The avatar scales with Dynamic Type up to here, so the largest text sizes leave the
    /// width to the name and address rather than to the picture.
    static let maxAvatarSize: CGFloat = 56
    static let horizontalPadding: CGFloat = 16
    static let avatarTextSpacing: CGFloat = 12

    static func clampedAvatar(_ scaled: CGFloat) -> CGFloat {
        min(scaled, max(avatarSize, maxAvatarSize))
    }

    static func dividerInset(avatar: CGFloat) -> CGFloat {
        horizontalPadding + avatar + avatarTextSpacing
    }
}

/// One contact in the To: field's suggestion list. Its own view, because the section is
/// also reached as a plain value (`ComposeView` reads `autocompleteOverlay` off it), where
/// a `@ScaledMetric` would never be installed and would keep its default size.
/// Name and address follow Dynamic Type, the name a step above the address.
struct AutocompleteContactRow: View {
    let contact: ContactsService.ContactMatch

    @ScaledMetric(relativeTo: .title3) private var nameSize: CGFloat = AutocompleteContactRowMetrics.nameSize
    @ScaledMetric(relativeTo: .callout) private var emailSize: CGFloat = AutocompleteContactRowMetrics.emailSize
    @ScaledMetric(relativeTo: .title3) private var scaledAvatarSize: CGFloat = AutocompleteContactRowMetrics.avatarSize

    init(contact: ContactsService.ContactMatch) {
        self.contact = contact
    }

    private var avatarSize: CGFloat {
        AutocompleteContactRowMetrics.clampedAvatar(scaledAvatarSize)
    }

    var body: some View {
        HStack(spacing: AutocompleteContactRowMetrics.avatarTextSpacing) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.system(size: nameSize))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(contact.primaryEmail)
                    .font(.system(size: emailSize))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, AutocompleteContactRowMetrics.horizontalPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let imageData = contact.imageData,
           let image = PlatformImage(data: imageData) {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Color.systemGray4)
                    .frame(width: avatarSize, height: avatarSize)
                Text(contact.displayName.prefix(1).uppercased())
                    .font(.system(size: avatarSize * 0.4, weight: .medium))
                    .foregroundColor(.white)
            }
        }
    }
}

/// The hairline under each suggestion, inset to start under the name.
struct AutocompleteContactRowDivider: View {
    @ScaledMetric(relativeTo: .title3) private var scaledAvatarSize: CGFloat = AutocompleteContactRowMetrics.avatarSize

    init() {}

    var body: some View {
        Divider()
            .padding(
                .leading,
                AutocompleteContactRowMetrics.dividerInset(
                    avatar: AutocompleteContactRowMetrics.clampedAvatar(scaledAvatarSize)
                )
            )
    }
}
