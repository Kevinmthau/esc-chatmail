import SwiftUI

/// Sizes of a To: field suggestion row, shared by the row and its divider so the divider's
/// inset stays under the name. On the iPhone the text uses the system's own text styles,
/// like Mail's and Contacts' pickers, so it follows the phone's text size setting (Kevin,
/// 2026-11-25: use my system default text sizes; fixed 16 and 13 read too small, fixed 20
/// too big). The Mac has no Dynamic Type and its `.body` is 13 points, so it keeps the
/// old fixed sizes beside its 13-point body text.
enum AutocompleteContactRowMetrics {
    #if os(macOS)
    static let nameFont: Font = .system(size: 16)
    static let emailFont: Font = .system(size: 13)
    #else
    static let nameFont: Font = .body
    static let emailFont: Font = .subheadline
    #endif
    /// The avatar's size at the default text size; it scales with `.body`.
    static let avatarSize: CGFloat = 40
    /// The avatar stops growing here, so the largest text sizes leave the width to the
    /// name and address rather than to the picture.
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
struct AutocompleteContactRow: View {
    let contact: ContactsService.ContactMatch

    @ScaledMetric(relativeTo: .body) private var scaledAvatarSize: CGFloat = AutocompleteContactRowMetrics.avatarSize

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
                    .font(AutocompleteContactRowMetrics.nameFont)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(contact.primaryEmail)
                    .font(AutocompleteContactRowMetrics.emailFont)
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
    @ScaledMetric(relativeTo: .body) private var scaledAvatarSize: CGFloat = AutocompleteContactRowMetrics.avatarSize

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
