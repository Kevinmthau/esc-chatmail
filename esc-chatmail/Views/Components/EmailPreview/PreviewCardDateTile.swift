import SwiftUI

/// The month / day / weekday tile on the calendar invite and reservation summary cards, so
/// the two read as one family. An empty `weekdaySymbol` leaves its row out.
struct PreviewCardDateTile: View {
    let monthSymbol: String
    let dayNumber: String
    let weekdaySymbol: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(monthSymbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Text(dayNumber)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if !weekdaySymbol.isEmpty {
                Text(weekdaySymbol)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .frame(width: 70, height: 92)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.gradient)
        )
    }
}
