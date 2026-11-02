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

    /// Revert-check: `ReservationSummaryParser.cancelledStatementRegex` — "To CANCEL your
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

    /// Revert-check: the `wordCounts != [2, 2]` condition in
    /// `ReservationSummaryParser.namesInSegment`, without which this is "Jane Doe John Smith".
    func testBuildPreview_twoFullNamesOnOneLine_staysTwoPeople() throws {
        let model = try XCTUnwrap(preview(fields: "Players: John Smith, Jane Doe\nCourt: East Court"))

        XCTAssertEqual(model.peopleLine, "John Smith, Jane Doe")
    }

    /// Revert-check: `ReservationSummaryParser.isPeopleValueLine`.
    func testBuildPreview_shortLinesAfterPlayers_areNotPlayers() throws {
        let model = try XCTUnwrap(preview(fields: """
        Court: East Court
        Players:
        Thau, Kevin
        Thank you for your reservation
        DO NOT REPLY TO THIS EMAIL
        """))

        XCTAssertEqual(model.peopleLine, "Kevin Thau")
    }

    /// Revert-check: the `placeholderValueRegex` filter in `ReservationSummaryParser.labelledFields`.
    func testBuildPreview_placeholderGuests_doNotBlockLaterPlayers() throws {
        let model = try XCTUnwrap(preview(fields: "Guests: None\nPlayers: Thau, Kevin\nCourt: East Court"))

        XCTAssertEqual(model.peopleLine, "Kevin Thau")
    }

    func testBuildPreview_countOfOne_readsSingular() throws {
        let model = try XCTUnwrap(preview(fields: "Guests: 1\nCourt: East Court"))

        XCTAssertEqual(model.peopleLine, "1 guest")
    }

    // MARK: - Location

    /// Revert-check: the removed within-source dedup in `ReservationSummaryParser.lines(from:)`,
    /// which dropped the value and gave the label "Parking in rear" instead.
    func testBuildPreview_locationRepeatingTheVenueHeading_keepsIt() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            The River Club of NY
            Dear Member,
            Your reservation on Sunday, 11/01/2026 is confirmed for 01:00 PM - 02:00 PM.
            Location:
            The River Club of NY
            Parking in rear
            """,
            subject: "Court Reservation"
        ))

        XCTAssertEqual(model.locationLine, "The River Club of NY")
    }

    // MARK: - Status: stated, not hedged

    /// Revert-check: `ReservationSummaryParser.statesFact`, whose hedge check keeps the policy
    /// from reading as a cancellation that hides the booking and strikes its time through.
    func testBuildPreview_conditionalCancellationPolicy_staysConfirmed() throws {
        let model = try XCTUnwrap(preview(fields: """
        Court: East Court
        If your reservation is cancelled less than 24 hours before the start, a fee applies.
        """))

        XCTAssertEqual(model.status, .confirmed)
    }

    /// Revert-check: `policyTermsRegex` in `ReservationSummaryParser.statesFact`, the only
    /// guard here: nothing earlier in this sentence hedges it.
    func testBuildPreview_cancellationPolicyWithoutConditionalWord_staysConfirmed() throws {
        let model = try XCTUnwrap(preview(fields: """
        Court: East Court
        A reservation is cancelled less than 24 hours out at the member's expense.
        """))

        XCTAssertEqual(model.status, .confirmed)
    }

    /// Revert-check: `confirmedSubjectRegex` (`contains("confirm")` accepted "Please confirm").
    func testBuildPreview_subjectAskingToConfirm_isNotConfirmed() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/01/2026 at 1:00 PM is held.\nCourt: East Court",
            subject: "Please confirm your reservation"
        ))

        XCTAssertNil(model.status)
    }

    /// Revert-check: `unconfirmedClauseRegex` in `ReservationSummaryParser.resolvedStatus`.
    func testBuildPreview_pendingConfirmation_isNotConfirmed() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/01/2026 at 1:00 PM is pending confirmation.\nCourt: East Court",
            subject: "Court reservation"
        ))

        XCTAssertNil(model.status)
    }

    /// "Please" alone hedges nothing: "Please note" introduces the fact.
    func testBuildPreview_pleaseNoteConfirmed_isConfirmed() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Please note your reservation on 11/01/2026 at 1:00 PM is confirmed.\nCourt: East Court",
            subject: "Court reservation"
        ))

        XCTAssertEqual(model.status, .confirmed)
    }

    func testBuildPreview_onceConfirmedOrConfirmationEmail_isNotConfirmed() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Your reservation on 11/01/2026 at 1:00 PM is held.
            Once your booking is confirmed, a confirmation email will follow.
            Court: East Court
            """,
            subject: "Court reservation"
        ))

        XCTAssertNil(model.status)
    }

    // MARK: - Cancellation notice

    /// Revert-check: the same-sentence "cancel" check in
    /// `ReservationSummaryParser.cancellationNoticeHours`.
    func testBuildPreview_noticeForAnotherPolicy_isNotACancellationDeadline() throws {
        let model = try XCTUnwrap(preview(fields: """
        Court: East Court
        Pro requests need 48 hours notice.
        To cancel, call the desk.
        """))

        XCTAssertNil(model.cancellationLine)
    }

    // MARK: - Choosing the reservation's date

    /// Revert-check: `ReservationSummaryParser.isNonEventDate` in `reservationDate`, without
    /// which this is an Oct 25 card.
    func testBuildPreview_bookedOnStampAboveReservation_usesReservationDate() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Booked on: 10/25/2026
            Your reservation on 11/01/2026 is confirmed for 1:00 PM - 2:00 PM.
            Court: East Court
            """,
            subject: "Court Reservation"
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 – 2:00 PM")
    }

    /// Revert-check: `ReservationSummaryParser.holdsOnlyNonEventDates` in `timeRange`, without
    /// which the stamp's 9:12 AM is the reservation's time.
    func testBuildPreview_timedBookedOnStamp_doesNotSupplyTheTime() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Booked on: 10/25/2026 at 9:12 AM
            Time: 1:00 PM
            Date: 11/01/2026
            Court: East Court
            """,
            subject: "Court Reservation"
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 PM")
    }

    /// Revert-check: iterating every match in `ReservationSummaryParser.dateMatches`, and the
    /// `textAfterDate` step in `timeRange`.
    func testBuildPreview_stampAndReservationOnOneLine_usesTheReservation() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Booked on 10/25/2026 at 9:12 AM. Your reservation on 11/01/2026 at 1:00 PM stands.
            Court: East Court
            """,
            subject: "Court Reservation"
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 PM")
    }

    /// Revert-check: the `timeRange(inLine:)` preference in `reservationDate`.
    func testBuildPreview_unrelatedDateBeforeTimedLine_prefersTheTimedLine() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Your statement of 10/15/2026 is attached.
            Your reservation is 11/01/2026 1:00 PM - 2:00 PM.
            Court: East Court
            """,
            subject: "Court Reservation"
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 – 2:00 PM")
    }

    func testBuildPreview_cancelByDateBeforeReservation_isNotTheReservationDate() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: """
            Please cancel by 10/30/2026 5:00 PM if your plans change.
            Your court booking: 11/01/2026
            Court: East Court
            Time: 1:00 PM
            """,
            subject: "Court Reservation"
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 PM")
    }

    func testBuildPreview_courtIsBookedOnDate_isTheReservationDate() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your court is booked on 11/01/2026 at 1:00 PM.\nCourt: East Court",
            subject: "Court booking"
        ))

        XCTAssertEqual(model.dateTimeLine, "Sunday, Nov 1 • 1:00 PM")
    }

    // MARK: - Choosing the reservation's time

    /// Revert-check: `ReservationSummaryParser.hasImplausibleBareStart`, and the resume in
    /// `explicitRange` that still finds the range past the rejected start.
    func testBuildPreview_laneNumberBeforeRange_isNotTheStartHour() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/01/2026:\nLane 4 - 6:00 PM - 7:00 PM\nLane: 4",
            subject: "Bowling reservation"
        ))

        XCTAssertEqual(model.timeLine, "6:00 – 7:00 PM")
    }

    func testBuildPreview_courtNumberBeforeLoneTime_isNotARange() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/01/2026:\nCourt 3 - 7:00 PM\nCourt: 3",
            subject: "Court reservation"
        ))

        XCTAssertEqual(model.timeLine, "7:00 PM")
    }

    // MARK: - Title

    /// Revert-check: the spaced-dash requirement in `ReservationSummaryParser.subjectPrefixPattern`.
    func testBuildPreview_hyphenatedSubject_keepsItsFirstWord() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/01/2026 at 1:00 PM stands.\nCourt: East Court",
            subject: "Re-booking confirmed"
        ))

        XCTAssertEqual(model.title, "Re-booking confirmed")
    }

    func testBuildPreview_spacedDashPrefix_isStripped() throws {
        let model = try XCTUnwrap(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on 11/01/2026 at 1:00 PM stands.\nCourt: East Court",
            subject: "Reminder - Court reservation"
        ))

        XCTAssertEqual(model.title, "Court reservation")
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

    func testBuildPreview_onlyABookedOnDate_returnsNil() {
        XCTAssertNil(sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Booked on: 10/25/2026 at 9:12 AM\nYour reservation is held.\nCourt: East Court",
            subject: "Court Reservation"
        ))
    }

    // MARK: - Helpers

    /// A confirmed Nov 1 booking with `fields` after its sentence.
    private func preview(fields: String) -> ReservationSummaryPreviewModel? {
        sut.buildPreview(
            canonicalHTML: nil,
            bodyText: "Your reservation on Sunday, 11/01/2026 is confirmed for 01:00 PM - 02:00 PM.\n\(fields)",
            subject: "Court Reservation"
        )
    }
}
