import SwiftUI

/// The month / day / weekday tile on the calendar invite and reservation summary cards, so
/// the two read as one family. An empty `weekdaySymbol` leaves its row out.
struct PreviewCardDateTile: View {
    let monthSymbol: String
    let dayNumber: String
    let weekdaySymbol: String
    let color: Color
    @Environment(\.emailPreviewCardMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.dateTile.spacing) {
            Text(monthSymbol)
                .font(metrics.font(\.dateTile.monthSize, .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Text(dayNumber)
                .font(metrics.font(\.dateTile.daySize, .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if !weekdaySymbol.isEmpty {
                Text(weekdaySymbol)
                    .font(metrics.font(\.dateTile.weekdaySize, .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .frame(width: metrics.dateTile.size.width, height: metrics.dateTile.size.height)
        .background(
            RoundedRectangle(cornerRadius: metrics.dateTile.cornerRadius, style: .continuous)
                .fill(color.gradient)
        )
    }
}
