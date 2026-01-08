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

    /// Bubble size for chat message avatars (24x24)
    static let bubble = InitialsAvatarStyle(
        size: 24,
        fontSize: 10,
        borderColor: .clear,
        borderWidth: 0,
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

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.61, green: 0.64, blue: 0.78),  // #9BA3C7 - light purple
                Color(red: 0.42, green: 0.45, blue: 0.65)   // #6B74A6 - darker purple
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundGradient)

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
