import SwiftUI

// MARK: - Avatar View
struct AvatarView: View {
    let name: String

    private var initials: String {
        let components = name.components(separatedBy: " ")
        let initials = components.prefix(2).compactMap { $0.first }.map { String($0) }.joined()
        return initials.isEmpty ? "?" : initials
    }

    private var backgroundColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.gradient)

            Text(initials.uppercased())
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}
