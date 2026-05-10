import Foundation

struct CalendarInvitePreviewBuilder {
    func buildPreview(
        canonicalHTML: String,
        bodyText: String?,
        cleanedSnippet: String? = nil,
        senderName: String? = nil,
        senderEmail: String?,
        subject: String? = nil
    ) -> CalendarInvitePreviewModel? {
        let bodyLines = previewLines(from: normalizedBodyText(bodyText) ?? "")
        let htmlLines = previewLines(from: normalizedText(TextProcessing.extractPlainText(from: canonicalHTML)))
        let snippetLines = previewLines(from: normalizedText(cleanedSnippet))
        let lines = mergedLines(primary: bodyLines, secondary: htmlLines, tertiary: snippetLines)

        guard isLikelyGoogleCalendarInvite(
            subject: subject,
            lines: lines,
            canonicalHTML: canonicalHTML
        ) else {
            return nil
        }

        guard let title = resolvedTitle(subject: subject, lines: lines),
              let whenLine = resolvedWhenLine(subject: subject, lines: lines),
              let dateSummary = resolvedDateSummary(from: whenLine) else {
            return nil
        }

        return CalendarInvitePreviewModel(
            title: title,
            monthSymbol: dateSummary.monthSymbol,
            dayNumber: dateSummary.dayNumber,
            weekdaySymbol: dateSummary.weekdaySymbol,
            dateTimeLine: normalizedWhenLine(whenLine),
            locationLine: resolvedLocationLine(from: lines, canonicalHTML: canonicalHTML),
            organizerLine: resolvedOrganizerLine(
                from: lines,
                senderName: senderName,
                senderEmail: senderEmail
            ),
            status: resolvedStatus(subject: subject, lines: lines, canonicalHTML: canonicalHTML),
            actionLabel: "Open invite",
            sourceLabel: resolvedSourceLabel(lines: lines, canonicalHTML: canonicalHTML)
        )
    }

    private func isLikelyGoogleCalendarInvite(
        subject: String?,
        lines: [String],
        canonicalHTML: String
    ) -> Bool {
        let normalizedSubject = normalizedText(subject).lowercased()
        let lowercasedHTML = canonicalHTML.lowercased()
        let combinedText = lines.joined(separator: "\n").lowercased()

        let hasGoogleCalendarMarker =
            Self.googleCalendarMarkers.contains { lowercasedHTML.contains($0) } ||
            Self.googleCalendarMarkers.contains { combinedText.contains($0) }
        let hasInvitePrefix = Self.inviteSubjectPrefixes.contains { normalizedSubject.hasPrefix($0) }
        let hasCalendarStructure =
            lineFollowing(label: "when", in: lines) != nil &&
            (
                lineFollowing(label: "where", in: lines) != nil ||
                lineFollowing(label: "guests", in: lines) != nil ||
                combinedText.contains("reply for ") ||
                combinedText.contains("yes no maybe")
            )
        let hasDateTime = resolvedWhenLine(subject: subject, lines: lines) != nil

        return hasGoogleCalendarMarker || (hasInvitePrefix && hasDateTime && hasCalendarStructure)
    }

    private func resolvedTitle(subject: String?, lines: [String]) -> String? {
        let candidates: [String?] = [
            subjectTitle(from: subject),
            line(beforeLabel: "when", in: lines),
            firstSignificantTitleLine(in: lines)
        ]

        for candidate in candidates {
            let normalized = normalizedTitle(candidate)
            guard !normalized.isEmpty else {
                continue
            }

            return truncate(normalized, limit: 90)
        }

        return nil
    }

    private func resolvedWhenLine(subject: String?, lines: [String]) -> String? {
        if let whenLine = lineFollowing(label: "when", in: lines),
           looksLikeDateTime(whenLine) {
            return whenLine
        }

        if let subjectDateLine = subjectDateLine(from: subject),
           looksLikeDateTime(subjectDateLine) {
            return subjectDateLine
        }

        for line in lines where looksLikeDateTime(line) {
            return line
        }

        return nil
    }

    private func resolvedLocationLine(from lines: [String], canonicalHTML: String) -> String? {
        if let whereLine = lineFollowing(label: "where", in: lines) {
            if isGoogleMeetLine(whereLine) {
                return "Google Meet"
            }

            let normalized = normalizedMetadataLine(whereLine)
            if !normalized.isEmpty, !looksLikeDateTime(normalized) {
                return truncate(normalized, limit: 70)
            }
        }

        let combinedText = lines.joined(separator: "\n").lowercased()
        if isGoogleMeetLine(canonicalHTML) || combinedText.contains("meet.google.com") || combinedText.contains("google meet") {
            return "Google Meet"
        }

        return nil
    }

    private func resolvedOrganizerLine(
        from lines: [String],
        senderName: String?,
        senderEmail: String?
    ) -> String? {
        if let whoLine = lineFollowing(label: "who", in: lines) {
            let normalized = normalizedMetadataLine(whoLine)
            if !normalized.isEmpty,
               !isGenericCalendarSender(normalized) {
                return "Hosted by \(truncate(normalized, limit: 50))"
            }
        }

        let normalizedSenderName: String
        if let senderEmail {
            normalizedSenderName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                senderName,
                forEmail: senderEmail
            ) ?? ""
        } else {
            normalizedSenderName = normalizedMetadataLine(senderName)
        }
        if !normalizedSenderName.isEmpty,
           !isGenericCalendarSender(normalizedSenderName) {
            return "Hosted by \(truncate(normalizedSenderName, limit: 50))"
        }

        return nil
    }

    private func resolvedStatus(
        subject: String?,
        lines: [String],
        canonicalHTML: String
    ) -> String? {
        let subjectText = normalizedText(subject).lowercased()
        let combinedText = lines.joined(separator: "\n").lowercased()
        let lowercasedHTML = canonicalHTML.lowercased()

        if subjectText.hasPrefix("canceled:") || subjectText.hasPrefix("cancelled:") {
            return "Cancelled"
        }

        if subjectText.hasPrefix("updated invitation:") || combinedText.contains("updated invitation") {
            return "Updated"
        }

        if subjectText.hasPrefix("invitation:") ||
            combinedText.contains("invitation from google calendar") ||
            lowercasedHTML.contains("invitation from google calendar") {
            return "Invitation"
        }

        return nil
    }

    private func resolvedSourceLabel(lines: [String], canonicalHTML: String) -> String? {
        let lowercasedHTML = canonicalHTML.lowercased()
        let combinedText = lines.joined(separator: "\n").lowercased()

        if Self.googleCalendarMarkers.contains(where: { lowercasedHTML.contains($0) }) ||
            Self.googleCalendarMarkers.contains(where: { combinedText.contains($0) }) {
            return "Google Calendar"
        }

        return "Calendar"
    }

    private func previewLines(from rawText: String) -> [String] {
        guard !rawText.isEmpty else {
            return []
        }

        let rawLines = rawText.components(separatedBy: .newlines)
        var lines: [String] = []

        for line in rawLines {
            let normalized = normalizedText(line)
            guard !normalized.isEmpty else {
                continue
            }

            let comparable = normalized.lowercased()
            if lines.contains(where: { $0.lowercased() == comparable }) {
                continue
            }

            lines.append(normalized)
        }

        return lines
    }

    private func mergedLines(primary: [String], secondary: [String], tertiary: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()

        for line in primary + secondary + tertiary {
            let comparable = line.lowercased()
            if seen.contains(comparable) {
                continue
            }

            seen.insert(comparable)
            merged.append(line)
        }

        return merged
    }

    private func lineFollowing(label: String, in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() where normalizedMetadataLine(line).lowercased() == label {
            let followingIndex = lines.index(after: index)
            guard followingIndex < lines.endIndex else {
                return nil
            }

            let candidate = normalizedMetadataLine(lines[followingIndex])
            guard !candidate.isEmpty, !isNoiseLine(candidate) else {
                return nil
            }

            return candidate
        }

        return nil
    }

    private func line(beforeLabel label: String, in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() where normalizedMetadataLine(line).lowercased() == label {
            guard index > 0 else {
                return nil
            }

            let candidate = normalizedMetadataLine(lines[index - 1])
            guard !candidate.isEmpty,
                  !looksLikeDateTime(candidate),
                  !isNoiseLine(candidate) else {
                return nil
            }

            return candidate
        }

        return nil
    }

    private func firstSignificantTitleLine(in lines: [String]) -> String? {
        for line in lines {
            let candidate = normalizedMetadataLine(line)
            guard !candidate.isEmpty,
                  !looksLikeDateTime(candidate),
                  !isNoiseLine(candidate),
                  !candidate.contains("@"),
                  candidate.count >= 4 else {
                continue
            }

            return candidate
        }

        return nil
    }

    private func subjectTitle(from subject: String?) -> String? {
        let normalizedSubject = normalizedText(subject)
        guard !normalizedSubject.isEmpty else {
            return nil
        }

        let strippedPrefix = normalizedSubject.replacingOccurrences(
            of: #"^(?:updated\s+invitation|invitation|canceled|cancelled):\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        if let range = strippedPrefix.range(of: " @ ") {
            return String(strippedPrefix[..<range.lowerBound])
        }

        return strippedPrefix
    }

    private func subjectDateLine(from subject: String?) -> String? {
        let normalizedSubject = normalizedText(subject)
        guard !normalizedSubject.isEmpty,
              let range = normalizedSubject.range(of: " @ ") else {
            return nil
        }

        return String(normalizedSubject[range.upperBound...])
    }

    private func normalizedTitle(_ title: String?) -> String {
        normalizedText(title)
            .replacingOccurrences(
                of: #"^(?:invitation from google calendar)\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
    }

    private func normalizedWhenLine(_ line: String) -> String {
        normalizedText(line)
            .replacingOccurrences(of: "⋅", with: " • ")
            .replacingOccurrences(of: "·", with: " • ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMetadataLine(_ line: String?) -> String {
        normalizedText(line)
            .replacingOccurrences(of: #"^[-•\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNoiseLine(_ line: String) -> Bool {
        let lowercased = normalizedMetadataLine(line).lowercased()
        guard !lowercased.isEmpty else {
            return true
        }

        if Self.noiseLineValues.contains(lowercased) {
            return true
        }

        if lowercased.hasPrefix("reply for ") || lowercased.hasPrefix("view all guest") {
            return true
        }

        return false
    }

    private func isGoogleMeetLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("meet.google.com") || lowercased.contains("google meet")
    }

    private func isGenericCalendarSender(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("google calendar") ||
            lowercased == "calendar" ||
            lowercased.contains("calendar-notification@") ||
            lowercased.contains("@calendar.google.com")
    }

    private func looksLikeDateTime(_ line: String) -> Bool {
        if detectedDate(in: line) != nil {
            return true
        }

        return line.range(
            of: Self.datePattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func resolvedDateSummary(from whenLine: String) -> CalendarInviteDateSummary? {
        let normalizedLine = normalizedWhenLine(whenLine)

        if let regexSummary = regexDateSummary(from: normalizedLine) {
            return regexSummary
        }

        guard let detectedDate = detectedDate(in: normalizedLine) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "MMM"
        let monthSymbol = formatter.string(from: detectedDate).uppercased()

        formatter.dateFormat = "d"
        let dayNumber = formatter.string(from: detectedDate)

        formatter.dateFormat = "EEE"
        let weekdaySymbol = formatter.string(from: detectedDate).uppercased()

        return CalendarInviteDateSummary(
            monthSymbol: monthSymbol,
            dayNumber: dayNumber,
            weekdaySymbol: weekdaySymbol
        )
    }

    private func regexDateSummary(from line: String) -> CalendarInviteDateSummary? {
        let nsRange = NSRange(line.startIndex..., in: line)

        if let regex = try? NSRegularExpression(
            pattern: #"(?i)\b(mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\s+([A-Za-z]{3,9})\s+(\d{1,2})(?:,)?\s+(\d{4})"#,
            options: []
        ),
           let match = regex.firstMatch(in: line, options: [], range: nsRange),
           match.numberOfRanges >= 4,
           let weekdayRange = Range(match.range(at: 1), in: line),
           let monthRange = Range(match.range(at: 2), in: line),
           let dayRange = Range(match.range(at: 3), in: line) {
            return CalendarInviteDateSummary(
                monthSymbol: abbreviatedUppercase(String(line[monthRange])),
                dayNumber: String(line[dayRange]),
                weekdaySymbol: abbreviatedUppercase(String(line[weekdayRange]))
            )
        }

        if let regex = try? NSRegularExpression(
            pattern: #"(?i)\b([A-Za-z]{3,9})\s+(\d{1,2})(?:,)?\s+(\d{4})"#,
            options: []
        ),
           let match = regex.firstMatch(in: line, options: [], range: nsRange),
           match.numberOfRanges >= 3,
           let monthRange = Range(match.range(at: 1), in: line),
           let dayRange = Range(match.range(at: 2), in: line) {
            return CalendarInviteDateSummary(
                monthSymbol: abbreviatedUppercase(String(line[monthRange])),
                dayNumber: String(line[dayRange]),
                weekdaySymbol: ""
            )
        }

        return nil
    }

    private func detectedDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..., in: text)
              ) else {
            return nil
        }

        return match.date
    }

    private func normalizedBodyText(_ bodyText: String?) -> String? {
        guard let bodyText else {
            return nil
        }

        return normalizedText(RawEmailSourceSanitizer.extractDisplayText(from: bodyText))
    }

    private func normalizedText(_ text: String?) -> String {
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

    private func abbreviatedUppercase(_ text: String) -> String {
        String(text.prefix(3)).uppercased()
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let truncated = String(text.prefix(limit))
        guard let lastSpace = truncated.lastIndex(of: " "),
              truncated.distance(from: truncated.startIndex, to: lastSpace) >= limit - 18 else {
            return truncated + "…"
        }

        return String(truncated[..<lastSpace]) + "…"
    }

    private static let googleCalendarMarkers = [
        "google calendar",
        "calendar.google.com",
        "meet.google.com",
        "view all guest info",
        "reply for "
    ]

    private static let inviteSubjectPrefixes = [
        "invitation:",
        "updated invitation:",
        "canceled:",
        "cancelled:"
    ]

    private static let noiseLineValues: Set<String> = [
        "when",
        "where",
        "who",
        "guests",
        "yes",
        "no",
        "maybe",
        "more options",
        "invitation from google calendar"
    ]

    private static let datePattern = #"\b(?:mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b[\w\s,.:()\-–•]*\b\d{1,2}:\d{2}\s*(?:am|pm)\b"#
}

private struct CalendarInviteDateSummary {
    let monthSymbol: String
    let dayNumber: String
    let weekdaySymbol: String
}
