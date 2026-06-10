import XCTest
@testable import esc_chatmail

final class CalendarInvitePreviewBuilderTests: XCTestCase {
    private let sut = CalendarInvitePreviewBuilder()

    func testBuildPreview_extractsGoogleCalendarInvitationSummary() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <div>Invitation from Google Calendar</div>
            <div>SAB Class observation</div>
            <div>When</div>
            <div>Friday Apr 24, 2026 • 5:30pm – 6:30pm (Eastern Time - New York)</div>
            <div>Guests</div>
            <div>kmthau@gmail.com</div>
            <div>Reply for kmthau@gmail.com</div>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: """
            Invitation from Google Calendar
            SAB Class observation
            When
            Friday Apr 24, 2026 • 5:30pm – 6:30pm (Eastern Time - New York)
            Guests
            kmthau@gmail.com
            Reply for kmthau@gmail.com
            """,
            cleanedSnippet: "Invitation: SAB Class observation @ Fri Apr 24, 2026 5:30pm - 6:30pm (EDT)",
            senderName: "Google Calendar",
            senderEmail: "calendar-notification@google.com",
            subject: "Invitation: SAB Class observation @ Fri Apr 24, 2026 5:30pm - 6:30pm (EDT)"
        )

        XCTAssertEqual(result?.title, "SAB Class observation")
        XCTAssertEqual(result?.monthSymbol, "APR")
        XCTAssertEqual(result?.dayNumber, "24")
        XCTAssertEqual(result?.weekdaySymbol, "FRI")
        XCTAssertEqual(result?.status, "Invitation")
        XCTAssertEqual(result?.sourceLabel, "Google Calendar")
        XCTAssertEqual(result?.actionLabel, "Open invite")
        XCTAssertNil(result?.locationLine)
    }

    func testBuildPreview_extractsMeetLocationAndOrganizer() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <div>Invitation from Google Calendar</div>
            <div>Board sync</div>
            <div>When</div>
            <div>Monday May 5, 2026 • 9:00am – 9:30am (Eastern Time - New York)</div>
            <div>Where</div>
            <div>https://meet.google.com/abc-defg-hij</div>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: """
            Invitation from Google Calendar
            Board sync
            When
            Monday May 5, 2026 • 9:00am – 9:30am (Eastern Time - New York)
            Where
            https://meet.google.com/abc-defg-hij
            """,
            cleanedSnippet: nil,
            senderName: "Brynn",
            senderEmail: "brynn@example.com",
            subject: "Updated invitation: Board sync @ Mon May 5, 2026 9:00am - 9:30am (EDT)"
        )

        XCTAssertEqual(result?.title, "Board sync")
        XCTAssertEqual(result?.status, "Updated")
        XCTAssertEqual(result?.locationLine, "Google Meet")
        XCTAssertEqual(result?.organizerLine, "Hosted by Brynn")
    }

    func testCanBuildPreview_matchesBuildPreviewAvailability() {
        let inviteHTML = """
        <!DOCTYPE html>
        <html>
        <body>
            <div>Invitation from Google Calendar</div>
            <div>SAB Class observation</div>
            <div>When</div>
            <div>Friday Apr 24, 2026 • 5:30pm – 6:30pm (Eastern Time - New York)</div>
            <div>Guests</div>
            <div>kmthau@gmail.com</div>
            <div>Reply for kmthau@gmail.com</div>
        </body>
        </html>
        """
        let plainHTML = """
        <html><body><p>Lunch tomorrow?</p></body></html>
        """

        for (html, subject) in [
            (inviteHTML, "Invitation: SAB Class observation @ Fri Apr 24, 2026 5:30pm - 6:30pm (EDT)"),
            (plainHTML, "Lunch")
        ] {
            let canBuild = sut.canBuildPreview(
                canonicalHTML: html,
                bodyText: nil,
                cleanedSnippet: nil,
                subject: subject
            )
            let built = sut.buildPreview(
                canonicalHTML: html,
                bodyText: nil,
                cleanedSnippet: nil,
                senderName: nil,
                senderEmail: nil,
                subject: subject
            )

            XCTAssertEqual(canBuild, built != nil, "canBuildPreview must mirror buildPreview for subject: \(subject)")
        }
    }
}
