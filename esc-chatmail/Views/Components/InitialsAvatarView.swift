import SwiftUI

/// Style configuration for InitialsAvatarView
struct InitialsAvatarStyle {
    let size: CGFloat
    let fontSize: CGFloat
    let borderColor: Color
    let borderWidth: CGFloat
    let singleNamePrefixLength: Int

    /// Standard size for single conversation avatars (44x44)
    static let standard = InitialsAvatarStyle(
        size: 44,
        fontSize: 15,
        borderColor: .white,
        borderWidth: 2,
        singleNamePrefixLength: 2
    )

    /// Compact size for group avatar thumbnails (20x20)
    static let compact = InitialsAvatarStyle(
        size: 20,
        fontSize: 8,
        borderColor: Color(UIColor.systemBackground),
        borderWidth: 1.5,
        singleNamePrefixLength: 1
    )
}

/// Unified initials avatar view with configurable styles
struct InitialsAvatarView: View {
    let name: String
    let style: InitialsAvatarStyle

    init(name: String, style: InitialsAvatarStyle = .standard) {
        self.name = name
        self.style = style
    }

    private var initials: String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            let first = String(components[0].prefix(1))
            let last = String(components[1].prefix(1))
            return (first + last).uppercased()
        } else if let first = components.first {
            return String(first.prefix(style.singleNamePrefixLength)).uppercased()
        }
        return "?"
    }

    private var backgroundColor: Color {
        let hash = name.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.8)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)

            Text(initials)
                .font(.system(size: style.fontSize, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: style.size, height: style.size)
        .overlay(
            Circle()
                .stroke(style.borderColor, lineWidth: style.borderWidth)
        )
    }
}
