import SwiftUI

/// The centered time line the transcript draws above a row that starts a new day or follows a
/// long gap: the day in bold and the time, as in Messages ("**Today** 2:14 PM").
///
/// It is part of the row it stands above, not a row of its own, so the transcript's row
/// identities, its realization records and its newest-row check never see it
/// (`ChatTimestampSeparatorPolicy`).
struct ChatTimestampSeparator: View {
    let date: Date

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    var body: some View {
        let label = ChatTimestampSeparatorPolicy.label(
            for: date,
            now: Date(),
            calendar: calendar,
            locale: locale
        )
        // Interpolated rather than joined with `+`, which macOS 26 deprecates.
        let day = Text(label.day).fontWeight(.semibold)
        let time = Text(label.time)
        Text("\(day) \(time)")
            .font(Self.font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.top, Self.topPadding)
            .padding(.bottom, Self.bottomPadding)
            .accessibilityAddTraits(.isHeader)
    }

    /// 11 points, Messages' size on the Mac as read from a screenshot.
    static let font = Font.system(size: 11)
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 6
}
