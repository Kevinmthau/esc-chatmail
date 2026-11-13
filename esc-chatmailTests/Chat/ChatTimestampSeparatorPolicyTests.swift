import XCTest
@testable import esc_chatmail

/// When the Mac's transcript draws a time line above a row, and what it says
/// (`ChatTimestampSeparatorPolicy`). Pure, so these run in the iOS suite and in
/// `Mac.xctestplan`.
final class ChatTimestampSeparatorPolicyTests: XCTestCase {
    private typealias Policy = ChatTimestampSeparatorPolicy

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = locale
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Whether a row has a line

    /// Revert-check: returning false for a nil `previous` in `showsSeparator` makes this fail.
    func testShowsSeparator_conversationsFirstMessage_hasOne() {
        XCTAssertTrue(Policy.showsSeparator(previous: nil, current: date(2026, 11, 12, 9, 0), calendar: calendar))
    }

    /// Revert-check: deleting the same-day check from `showsSeparator` makes this fail.
    func testShowsSeparator_newDay_hasOneEvenMinutesApart() {
        XCTAssertTrue(Policy.showsSeparator(
            previous: date(2026, 11, 11, 23, 58),
            current: date(2026, 11, 12, 0, 2),
            calendar: calendar
        ))
    }

    /// Revert-check: returning false after the same-day check in `showsSeparator` makes the
    /// first assertion fail; comparing with `>` makes the second fail; returning true makes
    /// the third fail.
    func testShowsSeparator_sameDay_onlyAfterTheGapThreshold() {
        let start = date(2026, 11, 12, 9, 0)
        XCTAssertEqual(Policy.gapThreshold, 3600)
        XCTAssertTrue(Policy.showsSeparator(previous: start, current: date(2026, 11, 12, 11, 30), calendar: calendar))
        XCTAssertTrue(Policy.showsSeparator(previous: start, current: date(2026, 11, 12, 10, 0), calendar: calendar))
        XCTAssertFalse(Policy.showsSeparator(previous: start, current: date(2026, 11, 12, 9, 59), calendar: calendar))
    }

    /// The day is the calendar's, not UTC's: 11 PM and 11:30 PM in New York are one day,
    /// though UTC's date changes between them.
    ///
    /// Revert-check: comparing the days with a UTC calendar in `showsSeparator` makes this fail.
    func testShowsSeparator_dayIsTheCalendarsOwn() {
        XCTAssertFalse(Policy.showsSeparator(
            previous: date(2026, 11, 12, 18, 50),
            current: date(2026, 11, 12, 19, 10),
            calendar: calendar
        ))
    }

    // MARK: - What the line says

    /// Revert-check: changing a bound in `dayForm`'s `switch` makes this fail.
    func testDayForm_byHowLongAgoTheDayWas() {
        let now = date(2026, 11, 12, 15, 0)
        XCTAssertEqual(Policy.dayForm(for: date(2026, 11, 12, 0, 1), now: now, calendar: calendar), .relative)
        // Yesterday by the calendar, though less than 24 hours ago.
        XCTAssertEqual(Policy.dayForm(for: date(2026, 11, 11, 23, 59), now: now, calendar: calendar), .relative)
        XCTAssertEqual(Policy.dayForm(for: date(2026, 11, 10, 9, 0), now: now, calendar: calendar), .weekday)
        XCTAssertEqual(Policy.dayForm(for: date(2026, 11, 6, 9, 0), now: now, calendar: calendar), .weekday)
        // A week ago today would read as today's weekday.
        XCTAssertEqual(Policy.dayForm(for: date(2026, 11, 5, 9, 0), now: now, calendar: calendar), .dateInThisYear)
        XCTAssertEqual(Policy.dayForm(for: date(2025, 12, 31, 9, 0), now: now, calendar: calendar), .dateWithYear)
        // A date ahead of the clock is named in full.
        XCTAssertEqual(Policy.dayForm(for: date(2026, 11, 14, 9, 0), now: now, calendar: calendar), .dateInThisYear)
    }

    /// Revert-check: swapping two templates in `label`'s `switch` makes this fail.
    func testLabel_dayAndTimeInTheLocalesWords() {
        let now = date(2026, 11, 12, 15, 0)
        func label(_ date: Date) -> Policy.Label {
            Policy.label(for: date, now: now, calendar: calendar, locale: locale)
        }

        let today = label(date(2026, 11, 12, 14, 14))
        XCTAssertEqual(today.day, "Today")
        // The space before AM/PM is a narrow no-break space on current systems.
        XCTAssertEqual(today.time.replacingOccurrences(of: "\u{202F}", with: " "), "2:14 PM")

        XCTAssertEqual(label(date(2026, 11, 11, 9, 0)).day, "Yesterday")
        XCTAssertEqual(label(date(2026, 11, 10, 9, 0)).day, "Tuesday")
        XCTAssertEqual(label(date(2026, 11, 3, 9, 0)).day, "Tue, Nov 3")
        XCTAssertEqual(label(date(2025, 12, 31, 9, 0)).day, "Dec 31, 2025")
    }

    /// "Today" and "Yesterday" are the days `now` says they are, whatever the system clock
    /// reads. A `now` years before the clock and one years after it, so neither can ever be
    /// the day the test runs on. The test above passed only on 2026-11-12, the day it was
    /// written, and failed on CI from the 13th: the formatter named the days by the clock.
    ///
    /// Revert-check: setting `dayDate` to `date` in the `.relative` case of `label` makes
    /// this fail, with a date in place of each word.
    func testLabel_todayAndYesterday_areNowsNotTheClocks() {
        let nows = [date(2020, 3, 9, 15, 0), date(2090, 7, 4, 15, 0)]
        for now in nows {
            let earlierToday = calendar.date(byAdding: .hour, value: -6, to: now)!
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!
            func day(_ date: Date) -> String {
                Policy.label(for: date, now: now, calendar: calendar, locale: locale).day
            }

            XCTAssertEqual(day(earlierToday), "Today")
            XCTAssertEqual(day(yesterday), "Yesterday")
            // The day before is no longer a relative day, so its own date is formatted.
            XCTAssertNotEqual(day(twoDaysAgo), "Yesterday")
            XCTAssertNotEqual(day(twoDaysAgo), "Today")
        }
    }

    /// The time beside a relative day is the message's own, not the stand-in day's.
    ///
    /// Revert-check: giving the time formatter `dayDate` in `label` makes this fail.
    func testLabel_relativeDay_keepsTheMessagesOwnTime() {
        let now = date(2020, 3, 9, 15, 0)
        let label = Policy.label(for: date(2020, 3, 8, 7, 5), now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(label.day, "Yesterday")
        XCTAssertEqual(label.time.replacingOccurrences(of: "\u{202F}", with: " "), "7:05 AM")
    }
}
