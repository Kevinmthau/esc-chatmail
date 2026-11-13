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

        // The date the day formatter is given: `date`, except for a relative day.
        var dayDate = date

        switch dayForm(for: date, now: now, calendar: calendar) {
        case .relative:
            // "Today" and "Yesterday", in the locale's own words.
            dayFormatter.dateStyle = .medium
            dayFormatter.timeStyle = .none
            dayFormatter.doesRelativeDateFormatting = true
            // The formatter picks the word by the system clock, not by `now`, and there is
            // no way to hand it another one. So it is given the day that is as far behind
            // the clock as `date` is behind `now`: the clock's own today or yesterday. Given
            // `date` itself, a day that was today by `now` was named by the clock's today
            // instead: the line for a `now` of 2026-11-12 read "Yesterday" on the 13th, which
            // is how the test with that fixed `now` began to fail a day after it was written.
            let daysAgo = daysBetween(date, and: now, calendar: calendar)
            dayDate = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? date
        case .weekday:
            dayFormatter.setLocalizedDateFormatFromTemplate("EEEE")
        case .dateInThisYear:
            dayFormatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        case .dateWithYear:
            dayFormatter.setLocalizedDateFormatFromTemplate("MMMdy")
        }

        return Label(day: dayFormatter.string(from: dayDate), time: timeFormatter.string(from: date))
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
        switch daysBetween(date, and: now, calendar: calendar) {
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

    /// How many calendar days `date`'s day is before `now`'s: 0 for the same day, negative
    /// for a day ahead of `now`.
    private static func daysBetween(_ date: Date, and now: Date, calendar: Calendar) -> Int {
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? Int.max
    }
}
