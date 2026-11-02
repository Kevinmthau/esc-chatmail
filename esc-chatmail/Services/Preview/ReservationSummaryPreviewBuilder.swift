import Foundation

/// Builds the reservation summary card (`ReservationSummaryPreviewModel`) for a
/// booking-system reservation email, from `ReservationSummaryParser`.
///
/// Reached only for rows `Message.isLikelyCalendarInvite` routed as calendar events
/// (an `.ics` attachment plus a parseable reservation), after the Google Calendar
/// invite builder declined: `EmailPreviewPipeline` checks the request's flag, so a
/// reservation-shaped transactional mail without a calendar attachment keeps the
/// transactional card it had.
///
/// The parsed lines are the stored body text first and the canonical HTML's text after
/// it (`lines(bodyText:canonicalHTML:)`). The row gate parses the body text alone, which
/// is a prefix of these lines, so a row the gate routes here is a row this builder cards.
struct ReservationSummaryPreviewBuilder {
    func buildPreview(
        canonicalHTML: String?,
        bodyText: String?,
        senderName: String? = nil,
        senderEmail: String? = nil,
        subject: String?
    ) -> ReservationSummaryPreviewModel? {
        guard let summary = ReservationSummaryParser.parse(
            subject: subject,
            lines: Self.lines(bodyText: bodyText, canonicalHTML: canonicalHTML)
        ) else {
            return nil
        }

        return model(
            for: summary,
            fallbackSourceLabel: fallbackSourceLabel(senderName: senderName, senderEmail: senderEmail)
        )
    }

    /// True exactly when `buildPreview` would return a model; sender identity never
    /// affects it, which keeps the bubble's HTML-analysis cache key sender-free.
    func canBuildPreview(canonicalHTML: String?, bodyText: String?, subject: String?) -> Bool {
        ReservationSummaryParser.parse(
            subject: subject,
            lines: Self.lines(bodyText: bodyText, canonicalHTML: canonicalHTML)
        ) != nil
    }

    /// The row gate's lines: the stored body text, as display text.
    static func lines(bodyText: String?) -> [String] {
        ReservationSummaryParser.lines(
            from: bodyText.map { RawEmailSourceSanitizer.extractDisplayText(from: $0) }
        )
    }

    static func lines(bodyText: String?, canonicalHTML: String?) -> [String] {
        let htmlLines = canonicalHTML.map {
            ReservationSummaryParser.lines(from: TextProcessing.extractPlainText(from: $0))
        } ?? []
        return ReservationSummaryParser.mergedLines(lines(bodyText: bodyText), htmlLines)
    }

    func model(
        for summary: ReservationSummaryParser.Summary,
        fallbackSourceLabel: String? = nil
    ) -> ReservationSummaryPreviewModel? {
        guard let startDate = ReservationSummaryParser.date(of: summary.day, at: summary.startTime) else {
            return nil
        }

        let formatter = Self.makeFormatter()

        formatter.dateFormat = "MMM"
        let monthSymbol = formatter.string(from: startDate).uppercased()
        formatter.dateFormat = "d"
        let dayNumber = formatter.string(from: startDate)
        formatter.dateFormat = "EEE"
        let weekdaySymbol = formatter.string(from: startDate).uppercased()
        formatter.dateFormat = "EEEE, MMM d"
        let dateLine = formatter.string(from: startDate)
        let timeLine = Self.timeLine(start: summary.startTime, end: summary.endTime)

        return ReservationSummaryPreviewModel(
            title: summary.title,
            monthSymbol: monthSymbol,
            dayNumber: dayNumber,
            weekdaySymbol: weekdaySymbol,
            timeLine: timeLine,
            dateTimeLine: "\(dateLine) • \(timeLine)",
            locationLine: summary.location,
            peopleLine: Self.peopleLine(summary.people),
            cancellationLine: Self.cancellationLine(
                startDate: startDate,
                noticeHours: summary.cancellationNoticeHours
            ),
            status: summary.status,
            sourceLabel: summary.venue ?? fallbackSourceLabel
        )
    }

    // MARK: - Formatting

    /// "1:00 – 2:00 PM" when both ends share AM/PM, "11:30 AM – 12:30 PM" when not,
    /// "7:30 PM" with no end.
    static func timeLine(
        start: ReservationSummaryParser.Summary.Time,
        end: ReservationSummaryParser.Summary.Time?
    ) -> String {
        guard let end else {
            return clockTime(start, includesMeridiem: true)
        }

        if isPM(start) == isPM(end) {
            return "\(clockTime(start, includesMeridiem: false)) – \(clockTime(end, includesMeridiem: true))"
        }
        return "\(clockTime(start, includesMeridiem: true)) – \(clockTime(end, includesMeridiem: true))"
    }

    private static func clockTime(_ time: ReservationSummaryParser.Summary.Time, includesMeridiem: Bool) -> String {
        let hour = time.hour % 12 == 0 ? 12 : time.hour % 12
        let clock = "\(hour):\(String(format: "%02d", time.minute))"
        guard includesMeridiem else {
            return clock
        }
        return "\(clock) \(isPM(time) ? "PM" : "AM")"
    }

    private static func isPM(_ time: ReservationSummaryParser.Summary.Time) -> Bool {
        time.hour >= 12
    }

    private static func peopleLine(_ people: [String]) -> String? {
        guard !people.isEmpty else {
            return nil
        }
        let shown = people.prefix(3).joined(separator: ", ")
        let remaining = people.count - 3
        return remaining > 0 ? "\(shown) +\(remaining)" : shown
    }

    /// Wall-clock arithmetic in the parser's fixed zone: "24 hours notice" for a 1:00 PM
    /// booking means 1:00 PM the day before, even across a daylight-saving change.
    private static func cancellationLine(startDate: Date, noticeHours: Int?) -> String? {
        guard let noticeHours,
              let deadline = ReservationSummaryParser.gregorian.date(
                byAdding: .hour,
                value: -noticeHours,
                to: startDate
              ) else {
            return nil
        }

        let formatter = makeFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let deadlineTime = ReservationSummaryParser.gregorian.dateComponents([.hour, .minute], from: deadline)
        let time = ReservationSummaryParser.Summary.Time(
            hour: deadlineTime.hour ?? 0,
            minute: deadlineTime.minute ?? 0
        )
        return "Cancel by \(formatter.string(from: deadline)), \(clockTime(time, includesMeridiem: true))"
    }

    /// English, fixed-zone formatting: the card restates an English email's wall-clock
    /// date, so neither the device locale nor its zone may shift it.
    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = ReservationSummaryParser.gregorian
        formatter.timeZone = ReservationSummaryParser.gregorian.timeZone
        return formatter
    }

    private func fallbackSourceLabel(senderName: String?, senderEmail: String?) -> String? {
        guard let senderEmail else {
            let trimmed = senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return PersonDisplayNameResolver.sanitizedExplicitDisplayName(senderName, forEmail: senderEmail)
    }
}
