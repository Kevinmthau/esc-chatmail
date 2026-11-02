import SwiftUI

/// Summary card for a booking-system reservation (`ReservationSummaryPreviewModel`): the
/// venue and status, a date tile, and what / when / where / who, plus the cancellation
/// deadline. Laid out like `CalendarInvitePreviewCard`, which it sits beside in the same
/// route, so the two read as one family; a cancelled booking strikes its time through.
struct ReservationSummaryPreviewCard: View {
    let model: ReservationSummaryPreviewModel

    private var isCancelled: Bool {
        model.status == .cancelled
    }

    private var accentColor: Color {
        isCancelled ? .gray : .teal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .top, spacing: 14) {
                PreviewCardDateTile(
                    monthSymbol: model.monthSymbol,
                    dayNumber: model.dayNumber,
                    weekdaySymbol: model.weekdaySymbol,
                    color: accentColor
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    detailRow(systemName: "clock", text: model.timeLine, weight: .semibold)
                        .strikethrough(isCancelled)

                    if let locationLine = model.locationLine {
                        detailRow(systemName: "mappin.and.ellipse", text: locationLine)
                    }

                    if let peopleLine = model.peopleLine {
                        detailRow(systemName: "person.2", text: peopleLine)
                    }

                    if let cancellationLine = model.cancellationLine {
                        detailRow(
                            systemName: "calendar.badge.exclamationmark",
                            text: cancellationLine,
                            isSecondary: true
                        )
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
        .emailPreviewCardChrome()
    }

    static func accessibilityLabel(for model: ReservationSummaryPreviewModel) -> String {
        [
            "Reservation",
            statusText(model.status),
            model.title,
            model.dateTimeLine,
            model.locationLine,
            model.peopleLine,
            model.cancellationLine
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.sourceLabel ?? "Reservation")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accentColor)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let status = Self.statusText(model.status) {
                Text(status)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(statusColor.opacity(0.14))
                    )
                    .lineLimit(1)
            }
        }
    }

    private func detailRow(
        systemName: String,
        text: String,
        weight: Font.Weight = .medium,
        isSecondary: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSecondary ? Color.secondary : accentColor)
                .frame(width: 14, alignment: .center)

            Text(text)
                .font(.system(size: isSecondary ? 12 : 13, weight: isSecondary ? .regular : weight))
                .foregroundStyle(isSecondary ? Color.secondary : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: - Status

    private var statusColor: Color {
        switch model.status {
        case .confirmed: return .green
        case .cancelled: return .red
        case .reminder, .none: return .secondary
        }
    }

    private static func statusText(_ status: ReservationSummaryParser.Summary.Status?) -> String? {
        switch status {
        case .confirmed: return "Confirmed"
        case .reminder: return "Reminder"
        case .cancelled: return "Cancelled"
        case .none: return nil
        }
    }
}
