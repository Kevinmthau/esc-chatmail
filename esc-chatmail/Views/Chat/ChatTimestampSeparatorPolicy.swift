import Foundation

/// When the transcript draws a centered time line above a row, and what the line says
/// (`MessageBubbleStyle.showsTimestampSeparators`; `docs/mac-imessage-ui-plan.md`, PR 4).
///
/// The line is decided from two stored dates, the row's and the one before it, so a row knows
/// whether it has one when it mounts. The row before is read past the loaded window's edge
/// (`VirtualScrollState.rowForGrouping`), so the first row of a window does not gain or lose
/// its line when older rows load above it.
enum ChatTimestampSeparatorPolicy {
    /// A gap this long between two messages on one day gets a line. Messages' own threshold was
    /// not measured.
    static let gapThreshold: TimeInterval = 60 * 60

    /// Whether the row dated `current` has a time line above it. `previous` is the date of the
    /// message before it in the conversation, nil for the conversation's first message.
    static func showsSeparator(previous: Date?, current: Date, calendar: Calendar) -> Bool {
        guard let previous else { return true }
        if !calendar.isDate(previous, inSameDayAs: current) { return true }
        return current.timeIntervalSince(previous) >= gapThreshold
    }

    /// The line's two parts: the day, which Messages draws bold, and the time.
    struct Label: Equatable {
        let day: String
        let time: String
    }

    static func label(
        for date: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> Label {
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = locale

        switch dayForm(for: date, now: now, calendar: calendar) {
        case .relative:
            // "Today" and "Yesterday", in the locale's own words.
            dayFormatter.dateStyle = .medium
            dayFormatter.timeStyle = .none
            dayFormatter.doesRelativeDateFormatting = true
        case .weekday:
            dayFormatter.setLocalizedDateFormatFromTemplate("EEEE")
        case .dateInThisYear:
            dayFormatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        case .dateWithYear:
            dayFormatter.setLocalizedDateFormatFromTemplate("MMMdy")
        }

        return Label(day: dayFormatter.string(from: date), time: timeFormatter.string(from: date))
    }

    /// How the day part of the line names its day.
    enum DayForm: Equatable {
        /// Today or yesterday.
        case relative
        /// Two to six days ago: the weekday alone names it.
        case weekday
        case dateInThisYear
        case dateWithYear
    }

    static func dayForm(for date: Date, now: Date, calendar: Calendar) -> DayForm {
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? Int.max
        switch daysAgo {
        case 0, 1:
            return .relative
        case 2...6:
            return .weekday
        default:
            // A date in the future (a wrong clock, a scheduled message) is named in full too.
            return calendar.component(.year, from: date) == calendar.component(.year, from: now)
                ? .dateInThisYear
                : .dateWithYear
        }
    }
}
