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
/// stored body text) and `ReservationSummaryPreviewBuilder` (the card, over the same lines
/// plus the HTML's text appended after them) both call `parse`, so the gate cannot route a
/// row the builder then fails to card.
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

        guard let dated = reservationDate(in: lines),
              let times = timeRange(in: lines, dated: dated) else {
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

    /// Display lines from free text: normalized, blank lines dropped, in order. Repeats stay:
    /// a field's value can legitimately repeat an earlier line ("Location:" then the venue
    /// heading the mail opens with), and dropping it would hand the label the line after.
    static func lines(from text: String?) -> [String] {
        let normalized = CalendarInviteSignals.normalizedSignalText(text)
        guard !normalized.isEmpty else {
            return []
        }

        return normalized
            .components(separatedBy: .newlines)
            .map { CalendarInviteSignals.normalizedSignalText($0) }
            .filter { !$0.isEmpty }
    }

    /// `primary` then the lines of `other` not in it, compared case-insensitively. Only ever
    /// adding lines means a parse that succeeds on `primary` also succeeds on the result,
    /// which is what lets the row gate and the card builder agree.
    static func mergedLines(_ primary: [String], _ other: [String]) -> [String] {
        let seen = Set(primary.map { $0.lowercased() })
        return primary + other.filter { !seen.contains($0.lowercased()) }
    }

    // MARK: - Date

    private struct DatedLine {
        let day: Summary.Day
        let lineIndex: Int
        /// The rest of the line past the date, where its time usually sits.
        let textAfterDate: String
    }

    private struct DateMatch {
        let day: Summary.Day
        let range: Range<String.Index>
    }

    /// The reservation's own date: the first that shares a line with a time, else the first.
    /// A mail can state others ahead of it, so a date worded as when the booking was made or
    /// as a deadline ("Booked on: 10/25/2026", "cancel by 10/30/2026") never counts. A mail
    /// stating only those has no reservation date to show, and declines.
    private static func reservationDate(in lines: [String]) -> DatedLine? {
        var firstDated: DatedLine?
        for (index, line) in lines.enumerated() {
            for match in dateMatches(in: line) where !isNonEventDate(match, in: line) {
                let dated = DatedLine(
                    day: match.day,
                    lineIndex: index,
                    textAfterDate: String(line[match.range.upperBound...])
                )
                if timeRange(inLine: line) != nil {
                    return dated
                }
                if firstDated == nil {
                    firstDated = dated
                }
            }
        }
        return firstDated
    }

    /// Every date the line states, in order.
    private static func dateMatches(in line: String) -> [DateMatch] {
        func matches(
            _ regex: NSRegularExpression,
            reading: (NSTextCheckingResult) -> Summary.Day?
        ) -> [DateMatch] {
            regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line)).compactMap { match in
                guard let range = Range(match.range, in: line), let day = reading(match) else {
                    return nil
                }
                return DateMatch(day: day, range: range)
            }
        }

        let found = matches(numericDateRegex) { numericDate($0, in: line) } +
            matches(monthFirstTextualDateRegex) { monthFirstTextualDate($0, in: line) } +
            matches(dayFirstTextualDateRegex) { dayFirstTextualDate($0, in: line) }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func isNonEventDate(_ match: DateMatch, in line: String) -> Bool {
        firstMatch(nonEventDatePrefixRegex, in: String(line[..<match.range.lowerBound])) != nil
    }

    /// A stamp or deadline line: nothing on it describes the reservation, including its time.
    private static func holdsOnlyNonEventDates(_ line: String) -> Bool {
        let matches = dateMatches(in: line)
        return !matches.isEmpty && matches.allSatisfy { isNonEventDate($0, in: line) }
    }

    /// "Sunday, 11/01/2026", "11/1/26". Read month-first (the US booking systems this
    /// targets), unless a stated weekday only fits the day-first reading.
    private static func numericDate(_ match: NSTextCheckingResult, in line: String) -> Summary.Day? {
        guard let first = intGroup(match, 2, in: line),
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

    /// "Saturday, November 7, 2026", "Nov 7th 2026".
    private static func monthFirstTextualDate(_ match: NSTextCheckingResult, in line: String) -> Summary.Day? {
        guard let monthName = stringGroup(match, 1, in: line),
              let month = monthNumber(monthName),
              let day = intGroup(match, 2, in: line),
              let year = intGroup(match, 3, in: line) else {
            return nil
        }
        return validDay(year: year, month: month, day: day)
    }

    /// "7 November 2026".
    private static func dayFirstTextualDate(_ match: NSTextCheckingResult, in line: String) -> Summary.Day? {
        guard let day = intGroup(match, 1, in: line),
              let monthName = stringGroup(match, 2, in: line),
              let month = monthNumber(monthName),
              let year = intGroup(match, 3, in: line) else {
            return nil
        }
        return validDay(year: year, month: month, day: day)
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

    /// The text past the date first ("confirmed for 01:00 PM - 02:00 PM" usually shares the
    /// sentence), then the date's own line and the two after it, then anywhere. Ranges beat
    /// lone times on each line, so "1:00 PM - 2:00 PM" is never read as just its start.
    private static func timeRange(in lines: [String], dated: DatedLine) -> TimeRange? {
        let nearby = Array(lines[dated.lineIndex..<min(lines.count, dated.lineIndex + 3)])
        for line in [dated.textAfterDate] + nearby + lines where !holdsOnlyNonEventDates(line) {
            if let range = timeRange(inLine: line) {
                return range
            }
        }
        return nil
    }

    private static func timeRange(inLine line: String) -> TimeRange? {
        explicitRange(in: line) ?? singleTime(in: line).map { TimeRange(start: $0, end: nil) }
    }

    /// A match that cannot be a range (a court number or day as its start) only consumes up
    /// to that start, so "Lane 4 - 6:00 PM - 7:00 PM" still finds "6:00 PM - 7:00 PM".
    private static func explicitRange(in line: String) -> TimeRange? {
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let match = timeRangeRegex.firstMatch(
                in: line,
                options: [],
                range: NSRange(searchStart..., in: line)
              ) {
            if let range = timeRange(from: match, in: line) {
                return range
            }
            guard let start = Range(match.range(at: 1), in: line) else {
                return nil
            }
            searchStart = start.upperBound
        }
        return nil
    }

    private static func timeRange(from match: NSTextCheckingResult, in line: String) -> TimeRange? {
        guard let startHour = intGroup(match, 1, in: line),
              let endHour = intGroup(match, 4, in: line),
              let endMeridiem = stringGroup(match, 6, in: line).flatMap(meridiem),
              !hasImplausibleBareStart(match, in: line) else {
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

    /// A start with neither minutes nor AM/PM is only a number, so it has to read as a time
    /// from what comes before it ("for 11 - 12:30 pm"). After a word that names something
    /// else ("Court 3 - 7:00 PM", "Nov 1 - 7:00 PM") it is that thing's number.
    private static func hasImplausibleBareStart(_ match: NSTextCheckingResult, in line: String) -> Bool {
        guard match.range(at: 2).location == NSNotFound,
              match.range(at: 3).location == NSNotFound,
              let start = Range(match.range(at: 1), in: line) else {
            return false
        }
        return firstMatch(bareRangeStartContextRegex, in: String(line[..<start.lowerBound])) == nil
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
                    guard isFieldValueLine(candidate), kind == .location || isPeopleValueLine(candidate) else {
                        break
                    }
                    values.append(candidate)
                    if kind == .location {
                        break
                    }
                    nextIndex += 1
                }
            }
            // "Guests: None" states no value, so a later label can still supply the field.
            values.removeAll { firstMatch(placeholderValueRegex, in: $0) != nil }

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

    /// Whether a line after a people label is more of that list: a bare count or names. The
    /// mail's next sentence often has no period and passes `isFieldValueLine`
    /// ("Thank you for your reservation", "DO NOT REPLY TO THIS EMAIL").
    private static func isPeopleValueLine(_ line: String) -> Bool {
        if Int(line) != nil {
            return true
        }
        guard firstMatch(peopleListEndRegex, in: line) == nil else {
            return false
        }
        return line.components(separatedBy: CharacterSet(charactersIn: ",;")).allSatisfy { name in
            isNameLike(name) && name.split(separator: " ").count <= 4
        }
    }

    /// "Thau, Kevin" reads "Kevin Thau"; "Thau, Kevin; Doe, Jane" is two people; a bare
    /// count ("4") reads "4 players" under its label.
    private static func peopleNames(in value: String, label: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let count = Int(trimmed) {
            let singular = label.hasSuffix("s") ? String(label.dropLast()) : label
            return ["\(count) \(count == 1 ? singular : singular + "s")"]
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
        // Two words on both sides ("John Smith, Jane Doe") is two people far more often than
        // one person with a two-word surname and two given names.
        if parts.count == 2,
           wordCounts.allSatisfy({ (1...2).contains($0) }),
           wordCounts != [2, 2],
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
    /// "To CANCEL your reservation, please email…" is an instruction, not a cancellation, and
    /// "If your reservation is cancelled less than 24 hours before…" is policy, so both
    /// statuses need a phrase stating it happened (`statesFact`).
    private static func resolvedStatus(lowercasedSubject: String, lowercasedText: String) -> Summary.Status? {
        if statesFact(cancelledSubjectRegex, in: lowercasedSubject, unlessClauseHas: conditionalClauseRegex) ||
            statesFact(cancelledStatementRegex, in: lowercasedText, unlessClauseHas: conditionalClauseRegex) {
            return .cancelled
        }
        if statesFact(confirmedSubjectRegex, in: lowercasedSubject, unlessClauseHas: unconfirmedClauseRegex) ||
            statesFact(confirmedStatementRegex, in: lowercasedText, unlessClauseHas: unconfirmedClauseRegex) {
            return .confirmed
        }
        if lowercasedSubject.contains("reminder") {
            return .reminder
        }
        return nil
    }

    /// Whether `regex` matches somewhere as a statement: not hedged earlier in its sentence
    /// ("if", "once", "pending"), and not followed by a policy's terms ("is cancelled less
    /// than 24 hours before").
    private static func statesFact(
        _ regex: NSRegularExpression,
        in text: String,
        unlessClauseHas hedge: NSRegularExpression
    ) -> Bool {
        regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let range = Range(match.range, in: text) else {
                return false
            }
            return firstMatch(hedge, in: String(text[sentenceStart(before: range.lowerBound, in: text)..<range.lowerBound])) == nil &&
                firstMatch(policyTermsRegex, in: String(text[range.upperBound...])) == nil
        }
    }

    /// "provide us with 24 hours notice of cancellation", "48-hour notice". Only a notice its
    /// own sentence ties to cancelling counts: "48 hours notice" for a pro request is not a
    /// cancellation deadline just because the mail also says how to cancel.
    private static func cancellationNoticeHours(in lowercasedText: String) -> Int? {
        let range = NSRange(lowercasedText.startIndex..., in: lowercasedText)
        for match in noticeHoursRegex.matches(in: lowercasedText, options: [], range: range) {
            guard let matched = Range(match.range, in: lowercasedText),
                  let hours = intGroup(match, 1, in: lowercasedText),
                  (1...336).contains(hours) else {
                continue
            }
            let sentenceEnd = lowercasedText[matched.upperBound...].firstIndex(where: isSentenceEnd) ?? lowercasedText.endIndex
            if lowercasedText[sentenceStart(before: matched.lowerBound, in: lowercasedText)..<sentenceEnd].contains("cancel") {
                return hours
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func isSentenceEnd(_ character: Character) -> Bool {
        ".!?;\n".contains(character)
    }

    private static func sentenceStart(before index: String.Index, in text: String) -> String.Index {
        text[..<index].lastIndex(where: isSentenceEnd).map { text.index(after: $0) } ?? text.startIndex
    }

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

    /// A date worded as something other than the reservation, ending right where the date
    /// starts: "Booked on: ", "Sent: Monday, ", "cancel by ". "Your court is booked on …" and
    /// "has been booked on …" do state the reservation, so they stay out.
    private static let nonEventDatePrefixRegex = regex(
        #"(?:(?<!is )(?<!been )\b(?:booked|made|created|placed|sent|received|purchased|issued|modified|updated|printed|generated)(?:\s+(?:on|at))?|\b(?:by|before|until|deadline))\s*:?\s*(?:\b(?:"# +
            weekdayPattern + #")\b\.?,?\s+)?$"#
    )

    /// "01:00 PM - 02:00 PM", "1-2pm", "11 to 12:30 p.m.". The end's AM/PM is required. The
    /// lookbehind keeps a date's trailing part ("11/01 - 2 PM") from being read as the start.
    private static let timeRangeRegex = regex(
        #"(?<![/\d])\b(\d{1,2})(?::(\d{2}))?\s*("# + meridiemPattern + #")?\s*(?:-|–|—|to|until)\s*(\d{1,2})(?::(\d{2}))?\s*("# +
            meridiemPattern + #")(?![a-z])"#
    )

    /// What may precede a bare-number range start: nothing, punctuation or a number (but not
    /// "#"), or a word that introduces a time.
    private static let bareRangeStartContextRegex = regex(
        #"(?:^\s*|[^a-zA-Z\s#]\s*|\b(?:for|from|at|time|times|between|is|on|today|tomorrow|"# +
            weekdayPattern + #")\b\.?,?\s*)$"#
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

    /// A dash only separates when spaced after the prefix: "Re-booking confirmed" and
    /// "Update-required reservation" start with hyphenated words, not with prefixes.
    private static let subjectPrefixPattern =
        #"^\s*(?:re|fwd?|reminder|friendly reminder|confirmation|confirmed|update|updated|important)\s*(?::\s*|[\-–]\s+)"#

    /// A line that ends a people list even though it reads like a short name.
    private static let peopleListEndRegex = regex(
        #"^(?:thank|thanks|regards|sincerely|cheers|best|please|questions?|note|see you|enjoy|do not|don['’]t)\b"#
    )

    private static let placeholderValueRegex = regex(#"^(?:|none|n/?a|tbd|-+|0)$"#)

    private static let cancelledSubjectRegex = regex(#"\bcancel(?:l?ed|l?ation)\b"#)

    private static let cancelledStatementRegex = regex(
        #"\b(?:reservation|booking)\s+(?:has been|was|is|have been)\s+cancel(?:l)?ed\b|\b(?:we have|we've|you have|you've)\s+cancel(?:l)?ed\b"#
    )

    private static let confirmedSubjectRegex = regex(#"\bconfirm(?:ed|ation)\b"#)

    /// "Confirmation" names a confirmed booking ("Confirmation #123"), but a follow-up one
    /// ("a confirmation email will follow") says nothing yet.
    private static let confirmedStatementRegex = regex(
        #"\b(?:is|has been|was|now) confirmed\b|\bconfirmation\b(?!\s+(?:e-?mail|message|link|required|needed|pending))"#
    )

    private static let conditionalClausePattern =
        "if|when|whenever|unless|should|once|until|after|before|any|each|every|in case|in the event"

    /// Hedges a cancellation or confirmation earlier in its sentence, making it a condition
    /// rather than a statement.
    private static let conditionalClauseRegex = regex(#"\b(?:"# + conditionalClausePattern + #")\b"#)

    /// The conditional hedges, plus the wording of a booking still waiting on a confirmation.
    private static let unconfirmedClauseRegex = regex(
        #"\b(?:"# + conditionalClausePattern + #"|pending|awaiting|await|waiting|requires?|required|needs?|upon|not)\b"#
    )

    /// What follows "is cancelled" in a policy rather than in a report of one.
    private static let policyTermsRegex = regex(#"^\s+(?:less|fewer|more|within|without|late|before|prior)\b"#)
}
