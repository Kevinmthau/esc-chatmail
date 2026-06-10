import Foundation

/// Single source of truth for the textual signals that identify a Google
/// Calendar invite email. `Message.isLikelyCalendarInvite` (the cheap
/// row-model gate) and `CalendarInvitePreviewBuilder` (card construction)
/// both match against these definitions so the two layers cannot drift.
enum CalendarInviteSignals {
    static let googleCalendarMarkers = [
        "google calendar",
        "calendar.google.com",
        "meet.google.com",
        "reply for ",
        "view all guest info"
    ]

    static let inviteSubjectPrefixes = [
        "invitation:",
        "updated invitation:",
        "canceled:",
        "cancelled:"
    ]

    /// Invite field labels as they appear in flattened plain text, where each
    /// label sits on its own line.
    static let structuralTextMarkers = [
        "\nwhen\n",
        "\nwhere\n",
        "\nguests\n",
        "\nmore options\n",
        "yes no maybe"
    ]

    static let dateTimePattern = #"\b(?:mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b[\w\s,.:()\-–•]*\b\d{1,2}:\d{2}\s*(?:am|pm)\b"#

    static func containsGoogleCalendarMarker(_ lowercasedText: String) -> Bool {
        googleCalendarMarkers.contains { lowercasedText.contains($0) }
    }

    static func hasInviteSubjectPrefix(_ lowercasedSubject: String) -> Bool {
        inviteSubjectPrefixes.contains { lowercasedSubject.hasPrefix($0) }
    }

    static func containsDateTimeSignal(_ text: String) -> Bool {
        text.range(
            of: dateTimePattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func normalizedSignalText(_ text: String?) -> String {
        guard let text else {
            return ""
        }

        return HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
