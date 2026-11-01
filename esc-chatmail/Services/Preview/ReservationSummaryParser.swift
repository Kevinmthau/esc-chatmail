import Foundation

/// Parses a booking-system reservation email (a court, tee time, lane, class or room
/// booking) into the handful of facts its summary card shows: what, when, where, who,
/// whether it stands, and the cancellation deadline.
///
/// The River Club's court-booking mail is the reference shape: an all-caps subject
/// ("REMINDER: TENNIS RESERVATION-with Pro"), the venue name above a "Dear Member,"
/// greeting, one sentence carrying the date and the time range
/// ("your reservation on Sunday, 11/01/2026 is confirmed for 01:00 PM - 02:00 PM."),
/// and `Label:` / value pairs ("Players:" then "Thau, Kevin", "Court:" then "East Court"),
/// where a value can sit on the label's line or on the lines after it.
///
/// Deliberately strict, because a parse is what routes a row to the card: it needs a
/// reservation keyword, a full date (with a year, so the weekday can be checked), a start
/// time with an AM/PM marker, and at least one labelled location or people field. Free
/// text that merely mentions a reservation and a time ("can we book 7:30 PM Friday?")
/// has no labelled field and stays a text bubble.
///
/// Pure and sender-independent: `Message.isLikelyCalendarInvite` (the row gate, over the
/// stored body text and snippet) and `ReservationSummaryPreviewBuilder` (the card, over
/// the same lines plus the HTML's text appended after them) both call `parse`, so the gate
/// cannot route a row the builder then fails to card.
enum ReservationSummaryParser {
    struct Summary: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case confirmed
            case reminder
            case cancelled
        }

        /// Wall-clock date as the email states it; no time zone is implied.
        struct Day: Equatable, Sendable {
            let year: Int
            let month: Int
            let day: Int
        }

        /// 24-hour wall-clock time.
        struct Time: Equatable, Sendable {
            let hour: Int
            let minute: Int
        }

        let title: String
        let venue: String?
        let day: Day
        let startTime: Time
        let endTime: Time?
        let location: String?
        let people: [String]
        let status: Status?
        /// Hours of notice the email requires to cancel without a charge; nil when it
        /// states none or the reservation is already cancelled.
        let cancellationNoticeHours: Int?
    }

    static func parse(subject: String?, lines: [String]) -> Summary? {
        let normalizedSubject = CalendarInviteSignals.normalizedSignalText(subject)
        let lowercasedSubject = normalizedSubject.lowercased()
        let lowercasedText = lines.joined(separator: "\n").lowercased()

        guard reservationKeywords.contains(where: {
            lowercasedSubject.contains($0) || lowercasedText.contains($0)
        }) else {
            return nil
        }

        guard let dated = firstDate(in: lines),
              let times = timeRange(in: lines, dateLineIndex: dated.lineIndex) else {
            return nil
        }

        let fields = labelledFields(in: lines)
        guard fields.location != nil || !fields.people.isEmpty else {
            return nil
        }

        let status = resolvedStatus(lowercasedSubject: lowercasedSubject, lowercasedText: lowercasedText)

        return Summary(
            title: title(fromSubject: normalizedSubject),
            venue: venue(in: lines, subject: normalizedSubject),
            day: dated.day,
            startTime: times.start,
            endTime: times.end,
            location: fields.location,
            people: fields.people,
            status: status,
            cancellationNoticeHours: status == .cancelled ? nil : cancellationNoticeHours(in: lowercasedText)
        )
    }

    /// Display lines from free text: normalized, blank lines dropped, repeats (compared
    /// case-insensitively) kept only once, in order.
    static func lines(from text: String?) -> [String] {
        let normalized = CalendarInviteSignals.normalizedSignalText(text)
        guard !normalized.isEmpty else {
            return []
        }

        var seen = Set<String>()
        var lines: [String] = []
        for rawLine in normalized.components(separatedBy: .newlines) {
            let line = CalendarInviteSignals.normalizedSignalText(rawLine)
            guard !line.isEmpty, seen.insert(line.lowercased()).inserted else {
                continue
            }
            lines.append(line)
        }
        return lines
    }

    /// `primary` then the lines of `others` not already present, compared case-insensitively.
    /// Appending keeps every match `parse` finds in `primary` ahead of anything later
    /// sources add, which is what lets the row gate and the card builder agree.
    static func mergedLines(_ primary: [String], _ others: [String]...) -> [String] {
        var seen = Set(primary.map { $0.lowercased() })
        var merged = primary
        for line in others.joined() where seen.insert(line.lowercased()).inserted {
            merged.append(line)
        }
        return merged
    }

    // MARK: - Date

    private struct DatedLine {
        let day: Summary.Day
        let lineIndex: Int
    }

    private static func firstDate(in lines: [String]) -> DatedLine? {
        for (index, line) in lines.enumerated() {
            if let day = numericDate(in: line) ?? textualDate(in: line) {
                return DatedLine(day: day, lineIndex: index)
            }
        }
        return nil
    }

    /// "Sunday, 11/01/2026", "11/1/26". Read month-first (the US booking systems this
    /// targets), unless a stated weekday only fits the day-first reading.
    private static func numericDate(in line: String) -> Summary.Day? {
        guard let match = firstMatch(numericDateRegex, in: line),
              let first = intGroup(match, 2, in: line),
              let second = intGroup(match, 3, in: line),
              let rawYear = intGroup(match, 4, in: line) else {
            return nil
        }

        let year = rawYear < 100 ? 2000 + rawYear : rawYear
        let statedWeekday = stringGroup(match, 1, in: line).flatMap(weekdayNumber)
        let monthFirst = validDay(year: year, month: first, day: second)
        let dayFirst = validDay(year: year, month: second, day: first)

        if let statedWeekday {
            if let monthFirst, weekday(of: monthFirst) == statedWeekday {
                return monthFirst
            }
            if let dayFirst, weekday(of: dayFirst) == statedWeekday {
                return dayFirst
            }
        }
        return monthFirst ?? dayFirst
    }

    /// "Saturday, November 7, 2026", "Nov 7th 2026", "7 November 2026".
    private static func textualDate(in line: String) -> Summary.Day? {
        if let match = firstMatch(monthFirstTextualDateRegex, in: line),
           let monthName = stringGroup(match, 1, in: line),
           let month = monthNumber(monthName),
           let day = intGroup(match, 2, in: line),
           let year = intGroup(match, 3, in: line) {
            return validDay(year: year, month: month, day: day)
        }

        if let match = firstMatch(dayFirstTextualDateRegex, in: line),
           let day = intGroup(match, 1, in: line),
           let monthName = stringGroup(match, 2, in: line),
           let month = monthNumber(monthName),
           let year = intGroup(match, 3, in: line) {
            return validDay(year: year, month: month, day: day)
        }

        return nil
    }

    private static func validDay(year: Int, month: Int, day: Int) -> Summary.Day? {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        // DateComponents rolls Feb 30 over into March; a round trip rejects it.
        let resolved = gregorian.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            return nil
        }
        return Summary.Day(year: year, month: month, day: day)
    }

    static func weekday(of day: Summary.Day) -> Int? {
        date(of: day, at: nil).map { gregorian.component(.weekday, from: $0) }
    }

    /// The day (and time) as a `Date` in `gregorian`'s fixed UTC zone. Only for calendar
    /// arithmetic and formatting with that same zone: the email states wall-clock times,
    /// so no conversion into the device's zone is meaningful.
    static func date(of day: Summary.Day, at time: Summary.Time?) -> Date? {
        gregorian.date(from: DateComponents(
            year: day.year,
            month: day.month,
            day: day.day,
            hour: time?.hour ?? 0,
            minute: time?.minute ?? 0
        ))
    }

    static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }()

    // MARK: - Time

    private struct TimeRange {
        let start: Summary.Time
        let end: Summary.Time?
    }

    /// The date's own line first ("confirmed for 01:00 PM - 02:00 PM" usually shares the
    /// sentence), then the two lines after it, then anywhere. Ranges beat lone times on
    /// each line, so "1:00 PM - 2:00 PM" is never read as just its start.
    private static func timeRange(in lines: [String], dateLineIndex: Int) -> TimeRange? {
        let nearby = (dateLineIndex..<min(lines.count, dateLineIndex + 3)).map { lines[$0] }
        for line in nearby + lines {
            if let range = explicitRange(in: line) ?? singleTime(in: line).map({ TimeRange(start: $0, end: nil) }) {
                return range
            }
        }
        return nil
    }

    private static func explicitRange(in line: String) -> TimeRange? {
        guard let match = firstMatch(timeRangeRegex, in: line),
              let startHour = intGroup(match, 1, in: line),
              let endHour = intGroup(match, 4, in: line),
              let endMeridiem = stringGroup(match, 6, in: line).flatMap(meridiem) else {
            return nil
        }

        let startMinute = intGroup(match, 2, in: line) ?? 0
        let endMinute = intGroup(match, 5, in: line) ?? 0
        guard let end = time(hour12: endHour, minute: endMinute, isPM: endMeridiem) else {
            return nil
        }

        let startMeridiem: Bool
        if let stated = stringGroup(match, 3, in: line).flatMap(meridiem) {
            startMeridiem = stated
        } else {
            // "11 - 12:30 PM" starts in the morning: a start that would land after the
            // end on the end's meridiem takes the other one.
            let sameMeridiemStart = time(hour12: startHour, minute: startMinute, isPM: endMeridiem)
            if let sameMeridiemStart, minutes(sameMeridiemStart) > minutes(end) {
                startMeridiem = !endMeridiem
            } else {
                startMeridiem = endMeridiem
            }
        }

        guard let start = time(hour12: startHour, minute: startMinute, isPM: startMeridiem) else {
            return nil
        }
        return TimeRange(start: start, end: end)
    }

    private static func singleTime(in line: String) -> Summary.Time? {
        guard let match = firstMatch(singleTimeRegex, in: line),
              let hour = intGroup(match, 1, in: line),
              let isPM = stringGroup(match, 3, in: line).flatMap(meridiem) else {
            return nil
        }
        return time(hour12: hour, minute: intGroup(match, 2, in: line) ?? 0, isPM: isPM)
    }

    private static func time(hour12: Int, minute: Int, isPM: Bool) -> Summary.Time? {
        guard (1...12).contains(hour12), (0...59).contains(minute) else {
            return nil
        }
        let hour = (hour12 % 12) + (isPM ? 12 : 0)
        return Summary.Time(hour: hour, minute: minute)
    }

    private static func minutes(_ time: Summary.Time) -> Int {
        time.hour * 60 + time.minute
    }

    /// True for PM, false for AM, nil for anything else.
    private static func meridiem(_ text: String) -> Bool? {
        switch text.lowercased().replacingOccurrences(of: ".", with: "") {
        case "am": return false
        case "pm": return true
        default: return nil
        }
    }

    // MARK: - Labelled fields

    private struct LabelledFields {
        var location: String?
        var people: [String] = []
    }

    private enum FieldKind {
        case location
        case people
    }

    /// `Label:` lines. A value on the label's own line is taken as is; an empty one takes
    /// the lines after it until the next label or a line that reads as prose (a sentence,
    /// or too long to be a name or a place). Location takes one value, people up to
    /// `maximumPeople`.
    private static func labelledFields(in lines: [String]) -> LabelledFields {
        var fields = LabelledFields()

        for (index, line) in lines.enumerated() {
            guard let match = firstMatch(labelRegex, in: line),
                  let label = stringGroup(match, 1, in: line)?.lowercased(),
                  let kind = fieldKind(forLabel: label) else {
                continue
            }

            let inlineValue = stringGroup(match, 2, in: line)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var values: [String] = []
            if !inlineValue.isEmpty {
                // An inline value is the label's own answer, so only the cheap prose
                // checks apply; a trailing period ("Court: East Court.") is just punctuation.
                guard inlineValue.count <= 60, !inlineValue.contains("@") else {
                    continue
                }
                values = [inlineValue.trimmingCharacters(in: CharacterSet(charactersIn: "."))]
            } else {
                var nextIndex = index + 1
                while nextIndex < lines.count, values.count < maximumPeople {
                    let candidate = lines[nextIndex]
                    guard isFieldValueLine(candidate) else {
                        break
                    }
                    values.append(candidate)
                    if kind == .location {
                        break
                    }
                    nextIndex += 1
                }
            }

            switch kind {
            case .location:
                if fields.location == nil, let value = values.first {
                    // "Lane: 4" reads "Lane 4"; "Court: East Court" already names itself.
                    let named = value.rangeOfCharacter(from: .letters) == nil
                        ? "\(label.capitalized) \(value)"
                        : value
                    fields.location = truncate(named, limit: 60)
                }
            case .people:
                guard fields.people.isEmpty else {
                    continue
                }
                fields.people = values
                    .flatMap { peopleNames(in: $0, label: label) }
                    .prefix(maximumPeople)
                    .map { $0 }
            }
        }

        return fields
    }

    private static func fieldKind(forLabel label: String) -> FieldKind? {
        if locationLabels.contains(label) {
            return .location
        }
        if peopleLabels.contains(label) {
            return .people
        }
        return nil
    }

    private static func isFieldValueLine(_ line: String) -> Bool {
        guard !line.isEmpty,
              line.count <= 60,
              firstMatch(labelRegex, in: line) == nil,
              !line.hasSuffix("."),
              !line.contains("@"),
              line.split(separator: " ").count <= 6 else {
            return false
        }
        return true
    }

    /// "Thau, Kevin" reads "Kevin Thau"; "Thau, Kevin; Doe, Jane" is two people; a bare
    /// count ("4") reads "4 players" under its label.
    private static func peopleNames(in value: String, label: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let count = Int(trimmed) {
            return ["\(count) \(label)"]
        }

        return trimmed
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap(namesInSegment)
    }

    private static func namesInSegment(_ segment: String) -> [String] {
        let parts = segment
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let wordCounts = parts.map { $0.split(separator: " ").count }
        if parts.count == 2,
           wordCounts.allSatisfy({ (1...2).contains($0) }),
           parts.allSatisfy(isNameLike),
           !nameSuffixes.contains(parts[1].lowercased().replacingOccurrences(of: ".", with: "")) {
            return ["\(parts[1]) \(parts[0])"]
        }

        if parts.count > 1, wordCounts.allSatisfy({ $0 >= 2 }) {
            return parts
        }

        return [segment]
    }

    private static func isNameLike(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || " .'-’".unicodeScalars.contains($0)
        }
    }

    // MARK: - Title, venue, status, notice

    /// The subject without its notice prefixes ("REMINDER:", "Confirmation:", "Fwd:"),
    /// out of all caps when it was shouting, and with a hyphen that joins a shouted word
    /// to a lowercase one spaced into a dash ("RESERVATION-with Pro" → "Reservation – with Pro").
    private static func title(fromSubject subject: String) -> String {
        var title = subject
        while let range = title.range(of: subjectPrefixPattern, options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(range)
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        title = title.replacingOccurrences(
            of: #"(?<=[A-Z]{2})-(?=[a-z])"#,
            with: " – ",
            options: .regularExpression
        )

        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let uppercase = letters.filter { CharacterSet.uppercaseLetters.contains($0) }
        if !letters.isEmpty, uppercase.count * 2 > letters.count {
            title = replacingMatches(of: shoutedWordRegex, in: title) { $0.capitalized }
        }

        guard !title.isEmpty else {
            return "Reservation"
        }
        return truncate(title, limit: 80)
    }

    /// The short line right above the greeting ("The River Club of NY" over "Dear Member,"),
    /// within the first few lines. nil when the mail opens differently: the builder falls
    /// back to the sender's name.
    private static func venue(in lines: [String], subject: String) -> String? {
        let searchedLines = lines.prefix(5)
        for (index, line) in searchedLines.enumerated() where index > 0 {
            guard firstMatch(greetingRegex, in: line) != nil else {
                continue
            }

            let candidate = lines[index - 1]
            guard candidate.count <= 48,
                  candidate.caseInsensitiveCompare(subject) != .orderedSame,
                  !candidate.contains(":"),
                  !candidate.contains("@"),
                  candidate.rangeOfCharacter(from: .decimalDigits) == nil,
                  firstMatch(greetingRegex, in: candidate) == nil else {
                return nil
            }
            return candidate
        }
        return nil
    }

    /// Cancelled outranks confirmed outranks reminder: a cancellation notice often quotes
    /// the booking it cancels, and a reminder usually restates that the booking stands.
    /// "To CANCEL your reservation, please email…" is an instruction, not a cancellation,
    /// so the text check needs a phrase stating one happened.
    private static func resolvedStatus(lowercasedSubject: String, lowercasedText: String) -> Summary.Status? {
        if lowercasedSubject.range(of: #"\bcancel(?:l?ed|lation)\b"#, options: .regularExpression) != nil ||
            lowercasedText.range(of: cancelledStatementPattern, options: .regularExpression) != nil {
            return .cancelled
        }
        if lowercasedSubject.contains("confirm") ||
            lowercasedText.range(of: #"\b(?:is|has been|was|now) confirmed\b|\bconfirmation\b"#, options: .regularExpression) != nil {
            return .confirmed
        }
        if lowercasedSubject.contains("reminder") {
            return .reminder
        }
        return nil
    }

    /// "provide us with 24 hours notice of cancellation", "48-hour notice". Only read when
    /// the mail talks about cancelling at all.
    private static func cancellationNoticeHours(in lowercasedText: String) -> Int? {
        guard lowercasedText.contains("cancel"),
              let match = firstMatch(noticeHoursRegex, in: lowercasedText),
              let hours = intGroup(match, 1, in: lowercasedText),
              (1...336).contains(hours) else {
            return nil
        }
        return hours
    }

    // MARK: - Helpers

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    private static func stringGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        stringGroup(match, index, in: text).flatMap { Int($0) }
    }

    private static func replacingMatches(
        of regex: NSRegularExpression,
        in text: String,
        transform: (String) -> String
    ) -> String {
        var result = text
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else {
                continue
            }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }

    private static func weekdayNumber(_ name: String) -> Int? {
        let prefix = String(name.lowercased().prefix(3))
        return ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: prefix).map { $0 + 1 }
    }

    private static func monthNumber(_ name: String) -> Int? {
        let prefix = String(name.lowercased().prefix(3))
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            .firstIndex(of: prefix)
            .map { $0 + 1 }
    }

    private static func regex(
        _ pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> NSRegularExpression {
        // The patterns are literals pinned by ReservationSummaryPreviewBuilderTests; a
        // pattern that failed to compile would fail every one of them, so `try!` cannot
        // reach a release build unnoticed.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // MARK: - Vocabulary

    private static let reservationKeywords = ["reservation", "booking", "booked"]

    private static let maximumPeople = 6

    private static let locationLabels: Set<String> = [
        "court", "courts", "location", "facility", "resource", "field", "lane",
        "room", "space", "venue", "studio", "bay", "table"
    ]

    private static let peopleLabels: Set<String> = [
        "players", "player", "participants", "participant", "guests", "guest",
        "attendees", "attendee", "members", "member"
    ]

    private static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "md", "phd"]

    private static let weekdayPattern =
        "monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thu|friday|fri|saturday|sat|sunday|sun"

    private static let monthPattern =
        "january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|" +
        "september|sept|sep|october|oct|november|nov|december|dec"

    private static let meridiemPattern = #"a\.?m\.?|p\.?m\.?"#

    private static let numericDateRegex = regex(
        #"(?:\b("# + weekdayPattern + #")\b\.?,?\s+)?\b(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})\b"#
    )

    private static let monthFirstTextualDateRegex = regex(
        #"\b("# + monthPattern + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#
    )

    private static let dayFirstTextualDateRegex = regex(
        #"\b(\d{1,2})(?:st|nd|rd|th)?\s+("# + monthPattern + #")\.?,?\s+(\d{4})\b"#
    )

    /// "01:00 PM - 02:00 PM", "1-2pm", "11 to 12:30 p.m.". The end's AM/PM is required.
    private static let timeRangeRegex = regex(
        #"\b(\d{1,2})(?::(\d{2}))?\s*("# + meridiemPattern + #")?\s*(?:-|–|—|to|until)\s*(\d{1,2})(?::(\d{2}))?\s*("# +
            meridiemPattern + #")(?![a-z])"#
    )

    private static let singleTimeRegex = regex(
        #"\b(\d{1,2})(?::(\d{2}))?\s*("# + meridiemPattern + #")(?![a-z])"#
    )

    /// A line that is a known-looking label: "Players:", "Court: East Court". Up to three
    /// words before the colon, so prose with a colon mid-sentence is not taken for one.
    private static let labelRegex = regex(#"^([A-Za-z]+(?:\s[A-Za-z]+){0,2})\s*:\s*(.*)$"#)

    private static let greetingRegex = regex(#"^(?:dear|hello|hi|hey|good (?:morning|afternoon|evening))\b"#)

    /// Case-sensitive on purpose: it must find only the words written in capitals.
    private static let shoutedWordRegex = regex(#"\b[A-Z]{3,}\b"#, options: [])

    private static let noticeHoursRegex = regex(
        #"\b(\d{1,3})\s*-?\s*(?:hours?|hrs?)(?:'|’)?s?\s+(?:advance\s+|advanced\s+|prior\s+)?notice\b"#
    )

    private static let subjectPrefixPattern =
        #"^\s*(?:re|fwd?|fw|reminder|friendly reminder|confirmation|confirmed|update|updated|important)\s*[:\-–]\s*"#

    private static let cancelledStatementPattern =
        #"\b(?:reservation|booking)\s+(?:has been|was|is|have been)\s+cancel(?:l)?ed\b|\b(?:we have|we've|you have|you've)\s+cancel(?:l)?ed\b"#
}
