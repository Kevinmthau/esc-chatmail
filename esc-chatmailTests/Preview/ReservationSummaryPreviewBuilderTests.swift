import XCTest
@testable import esc_chatmail

final class ReservationSummaryPreviewBuilderTests: XCTestCase {
    private let sut = ReservationSummaryPreviewBuilder()

    // MARK: - The River Club reminder

    /// Revert-check: `ReservationSummaryParser.parse` (the whole card) — without it this
    /// returns nil and the row stays the long text bubble from the bug report.
    func testBuildPreview_riverClubReminder_summarizesCourtReservation() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: ReservationEmailFixture.html,
            bodyText: ReservationEmailFixture.bodyText,
            senderName: ReservationEmailFixture.senderName,
            senderEmail: ReservationEmailFixture.senderEmail,
            subject: ReservationEmailFixture.subject
        ))

        XCTAssertEqual(model.title, "Tennis Reservation – with Pro")
        XCTAssertEqual(model.sourceLabel, "The River Club of NY")
        XCTAssertEqual(model.monthSymbol, "NOV")
        XCTAssertEqual(model.dayNumber, "1")
        XCTAssertEqual(model.weekdaySymbol, "SUN")
        XCTAssertEqual(model.timeLine, "1:00 – 2:00 PM")
        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 – 2:00 PM")
        XCTAssertEqual(model.locationLine, "East Court")
        XCTAssertEqual(model.peopleLine, "Kevin Thau")
        XCTAssertEqual(model.status, .confirmed)
        XCTAssertEqual(model.cancellationLine, "Cancel by Sat, Oct 31, 1:00 PM")
    }

    func testBuildPreview_htmlOnlyReminder_summarizesFromHTMLText() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: ReservationEmailFixture.html,
            bodyText: nil,
            subject: ReservationEmailFixture.subject
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 – 2:00 PM")
        XCTAssertEqual(model.locationLine, "East Court")
        XCTAssertEqual(model.peopleLine, "Kevin Thau")
    }

    func testCanBuildPreview_matchesBuildPreview() {
        XCTAssertTrue(sut.canBuildPreview(
            canonicalHTML: ReservationEmailFixture.html,
            bodyText: ReservationEmailFixture.bodyText,
            subject: ReservationEmailFixture.subject
        ))
        XCTAssertFalse(sut.canBuildPreview(
            canonicalHTML: nil,
            bodyText: "Can we book a court for 1:00 PM on 11/01/2026?",
            subject: "Tennis?"
        ))
    }

    /// The row gate parses only the stored body; the builder appends the HTML's text after
    /// it. Whatever the gate accepts, the builder must card.
    func testRowGateLines_areAPrefixOfBuilderLines() {
        let gateLines = ReservationSummaryPreviewBuilder.lines(bodyText: ReservationEmailFixture.bodyText)
        let builderLines = ReservationSummaryPreviewBuilder.lines(
            bodyText: ReservationEmailFixture.bodyText,
            canonicalHTML: ReservationEmailFixture.html
        )

        XCTAssertEqual(Array(builderLines.prefix(gateLines.count)), gateLines)
        XCTAssertNotNil(ReservationSummaryParser.parse(subject: ReservationEmailFixture.subject, lines: gateLines))
    }

    // MARK: - Status

    /// Revert-check: `ReservationSummaryParser.cancelledStatementPattern` — "To CANCEL your
    /// reservation" alone must not read as cancelled, but a stated cancellation must.
    func testBuildPreview_cancelledReservation_marksCancelledAndDropsDeadline() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            The River Club of NY
            Dear Member,
            Your reservation has been cancelled. It was on Sunday, 11/01/2026 for 01:00 PM - 02:00 PM.
            Court:
            East Court
            We ask that you provide us with 24 hours notice of cancellation for any reservation.
            """,
            subject: "TENNIS RESERVATION"
        ))

        XCTAssertEqual(model.status, .cancelled)
        XCTAssertNil(model.cancellationLine)
    }

    func testBuildPreview_cancelInstructionOnly_isNotCancelled() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: ReservationEmailFixture.bodyText,
            subject: ReservationEmailFixture.subject
        ))

        XCTAssertNotEqual(model.status, .cancelled)
    }

    func testBuildPreview_reminderWithoutConfirmation_marksReminder() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Your court reservation is on Saturday, November 7, 2026 at 9:00 AM.
            Court: 3
            """,
            subject: "Reminder: Court reservation"
        ))

        XCTAssertEqual(model.status, .reminder)
        XCTAssertEqual(model.locationLine, "Court 3")
        XCTAssertEqual(model.dateTimeLine, "Saturday, Nov 7 • 9:00 AM")
    }

    // MARK: - Date and time

    /// Revert-check: the weekday check in `ReservationSummaryParser.numericDate` — month-first
    /// alone reads 3/11/2026 as Wednesday, March 11.
    func testBuildPreview_numericDateWhoseWeekdayFitsDayFirst_readsDayFirst() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Booking confirmed: Tue 3/11/2026, 6:00 PM - 7:30 PM\nLane: 4",
            subject: "Bowling booking"
        ))

        XCTAssertEqual(model.monthSymbol, "NOV")
        XCTAssertEqual(model.dayNumber, "3")
        XCTAssertEqual(model.weekdaySymbol, "TUE")
        XCTAssertEqual(model.locationLine, "Lane 4")
    }

    func testBuildPreview_rangeWithoutStartMeridiem_crossingNoon_startsInMorning() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/08/2026 is confirmed for 11 - 12:30 pm.\nCourt: West Court",
            subject: "Reservation"
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 8 • 11:00 AM – 12:30 PM")
    }

    /// 24 hours before 1:00 PM on the day US daylight saving ends is 1:00 PM the day before
    /// on the wall clock, which is what a club means by "24 hours notice".
    func testBuildPreview_cancellationDeadline_usesWallClockAcrossDaylightSavingChange() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: ReservationEmailFixture.bodyText,
            subject: ReservationEmailFixture.subject
        ))

        XCTAssertEqual(model.cancellationLine, "Cancel by Sat, Oct 31, 1:00 PM")
    }

    // MARK: - People

    func testBuildPreview_severalLastFirstPlayers_readsFirstLastAndCaps() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Your reservation on Saturday, 11/07/2026 is confirmed for 9:00 AM - 10:30 AM.
            Players:
            Thau, Kevin
            Doe, Jane
            Roe, Richard
            Poe, Edgar
            Court:
            Clay Court 2
            """,
            subject: "Court Reservation"
        ))

        XCTAssertEqual(model.peopleLine, "Kevin Thau, Jane Doe, Richard Roe +1")
        XCTAssertEqual(model.locationLine, "Clay Court 2")
    }

    // MARK: - Declines

    func testBuildPreview_noLabelledField_returnsNil() {
        XCTAssertNil(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Could we move our reservation on 11/05/2026 to 7:30 PM? Let me know.",
            subject: "Dinner reservation"
        ))
    }

    func testBuildPreview_noTime_returnsNil() {
        XCTAssertNil(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/01/2026\nCourt: East Court",
            subject: "Reservation"
        ))
    }

    func testBuildPreview_noReservationKeyword_returnsNil() {
        XCTAssertNil(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Lesson on Sunday, 11/01/2026 from 01:00 PM - 02:00 PM.\nCourt:\nEast Court",
            subject: "Tennis lesson"
        ))
    }
}
