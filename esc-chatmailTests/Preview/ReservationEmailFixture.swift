import Foundation

/// The River Club of NY court-booking reminder, as it reached the chat: an all-caps
/// subject, the venue above "Dear Member,", a numeric date with a time range in one
/// sentence, `Label:` / value pairs on separate lines, and a 24-hour cancellation policy.
/// Transcribed from the rendered email; the attached `.ics` is represented only by its
/// filename and MIME type.
///
/// Kept beside the preview tests rather than in `TestSupport/Fixtures/`, whose edits
/// trigger the web CI.
enum ReservationEmailFixture {
    static let subject = "REMINDER: TENNIS RESERVATION-with Pro"
    static let senderName = "River Club Tennis"
    static let senderEmail = "tennis@riverclubnyc.com"
    static let calendarAttachmentFilename = "Tennis-Reservation-modified.ics"
    static let calendarAttachmentMimeType = "text/calendar"

    /// The stored plain-text body: paragraphs separated by blank lines, each label on its
    /// own line with its value on the next.
    static let bodyText = """
    The River Club of NY

    Dear Member,

    A kind reminder, your reservation on Sunday, 11/01/2026 is confirmed for 01:00 PM - 02:00 PM.

    Players:

    Thau, Kevin

    Court:

    East Court

    DO NOT REPLY TO THIS EMAIL.

    To CANCEL your reservation, please email tennis@riverclubnyc.com or call 212-751-0100 ext. 4001.

    We ask that you provide us with 24 hours notice of cancellation for any reservation.
    Reservations without 24 hours notice will result in a 100% charge of service.

    1 sleeve of tennis balls will be automatically included and billed to all general court reservations.

    Pro requests must be made at least 48 hours before the start of your booked court time by emailing tennis@riverclubnyc.com.
    """

    static let html = """
    <!DOCTYPE html>
    <html>
    <body>
      <div style="text-align:center">
        <img src="https://www.riverclubnyc.com/logo.png" alt="" width="60">
        <h2><em>The River Club of NY</em></h2>
        <p>Dear Member,<br>
        A kind reminder, your reservation on Sunday, 11/01/2026 is confirmed for 01:00 PM - 02:00 PM.</p>
        <p>Players:<br>Thau, Kevin</p>
        <p>Court:<br>East Court</p>
        <p><b>DO NOT REPLY TO THIS EMAIL.</b><br>
        <b>To CANCEL your reservation, please email
        <a href="mailto:tennis@riverclubnyc.com">tennis@riverclubnyc.com</a>
        or call <a href="tel:2127510100">212-751-0100 ext. 4001</a>.</b></p>
        <p>We ask that you provide us with 24 hours notice of cancellation for any reservation.<br>
        Reservations without 24 hours notice will result in a 100% charge of service.</p>
        <p>1 sleeve of tennis balls will be automatically included and billed to all general court reservations.</p>
        <p><b>Pro requests must be made at least 48 hours before the start of your booked court time by emailing
        <a href="mailto:tennis@riverclubnyc.com">tennis@riverclubnyc.com</a>.</b></p>
      </div>
    </body>
    </html>
    """
}
