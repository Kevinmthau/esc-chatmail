import Foundation

struct ForwardedMessageDisplayContent: Equatable, Sendable {
    let leadInText: String?
    let senderDisplayName: String?
    let senderEmail: String?
    let subject: String?
    let timestampText: String?
    let recipientSummary: String?
    let previewSnippet: String?

    var hasVisibleSummary: Bool {
        senderDisplayName != nil ||
        subject != nil ||
        timestampText != nil ||
        recipientSummary != nil ||
        previewSnippet != nil
    }
}

enum ForwardedMessageDisplayParser {
    private static let markerPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?i)(?:Begin forwarded message:|-{2,}[ \t]*Forwarded message\b(?:[ \t]*-{2,})?)"#,
            options: []
        )
    }()

    private static let knownHeaderNames: Set<String> = [
        "from",
        "date",
        "subject",
        "to",
        "cc"
    ]

    private static let leadingHeaderNoisePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[\s>\-]+"#, options: [])
    }()

    private static let dateDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    }()

    private static let inlineHeaderPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?i)\b(from|date|subject|to|cc):"#,
            options: []
        )
    }()

    private static let leadingEmailPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^[^@\s<>,]+@[^@\s<>,]+"#,
            options: []
        )
    }()

    static func parseForward(from text: String?) -> ForwardedMessageDisplayContent? {
        guard let text = normalized(text), !text.isEmpty else {
            return nil
        }

        guard let markerRange = markerRange(in: text) else {
            return nil
        }

        let leadInRaw = String(text[..<markerRange.lowerBound])
        let forwardedBlock = String(text[markerRange.upperBound...])
        let trimmedForwardedBlock = trimLeadingBlankLines(forwardedBlock)

        let parsedForward = parseForwardedBlock(trimmedForwardedBlock)
        let leadInText = cleanedLeadInText(from: leadInRaw)
        let sender = resolvedParticipant(from: parsedForward.headers["from"])
        let subject = cleanedHeaderValue(parsedForward.headers["subject"])
        let timestampText = cleanedTimestamp(from: parsedForward.headers["date"])
        let recipientSummary = resolvedRecipientSummary(from: parsedForward.headers["to"])
        let previewSnippet = resolvedPreviewSnippet(from: parsedForward.body)

        let content = ForwardedMessageDisplayContent(
            leadInText: leadInText,
            senderDisplayName: sender.displayName,
            senderEmail: sender.email,
            subject: subject,
            timestampText: timestampText,
            recipientSummary: recipientSummary,
            previewSnippet: previewSnippet
        )

        return content.hasVisibleSummary ? content : nil
    }

    static func parseOutgoingForward(from text: String?) -> ForwardedMessageDisplayContent? {
        parseForward(from: text)
    }

    private static func markerRange(in text: String) -> Range<String.Index>? {
        guard let markerPattern,
              let match = markerPattern.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text) else {
            return nil
        }

        return range
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }

        let decoded = HTMLEntityDecoder.decode(text)
        return decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func trimLeadingBlankLines(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let trimmedLines = Array(lines.drop(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        return trimmedLines.joined(separator: "\n")
    }

    private static func cleanedLeadInText(from text: String) -> String? {
        let result = ChatBubbleTextProcessor.plainTextOnlyFallback(
            from: text,
            sanitizeRawEmailSource: true,
            decodeHTMLEntities: false
        )
        if let mainText = trimmed(result.mainText) {
            return mainText
        }

        let fallbackText = RawEmailSourceSanitizer.extractDisplayText(from: text)
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: fallbackText)
        let formatted = TextProcessing.formatSignOffLineBreaks(in: unwrapped)
        return trimmed(formatted)
    }

    private static func cleanedHeaderValue(_ value: String?) -> String? {
        guard let decoded = normalized(value) else {
            return nil
        }

        return trimmed(decoded)
    }

    private static func cleanedTimestamp(from rawValue: String?) -> String? {
        guard let rawValue = cleanedHeaderValue(rawValue) else {
            return nil
        }

        guard let detector = dateDetector,
              let match = detector.firstMatch(
                in: rawValue,
                options: [],
                range: NSRange(rawValue.startIndex..., in: rawValue)
              ),
              let detectedDate = match.date else {
            return rawValue
        }

        let formatter = makeTimestampFormatter(
            includesYear: Calendar.current.component(.year, from: detectedDate) !=
                Calendar.current.component(.year, from: Date())
        )

        return formatter.string(from: detectedDate)
    }

    private static func makeTimestampFormatter(includesYear: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(includesYear ? "MMM d yyyy h:mm a" : "MMM d h:mm a")
        return formatter
    }

    private static func resolvedParticipant(
        from rawValue: String?
    ) -> (displayName: String?, email: String?) {
        guard let rawValue = cleanedHeaderValue(rawValue) else {
            return (nil, nil)
        }

        let email = EmailNormalizer.extractEmail(from: rawValue)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"' "))
        let displayName = EmailNormalizer.extractDisplayName(from: rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedDisplayName: String?
        if let email {
            sanitizedDisplayName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                displayName,
                forEmail: email
            )
        } else {
            sanitizedDisplayName = trimmed(displayName) ?? trimmed(rawValue)
        }

        return (
            sanitizedDisplayName,
            trimmed(email)
        )
    }

    private static func resolvedRecipientSummary(from rawValue: String?) -> String? {
        guard let rawValue = cleanedHeaderValue(rawValue) else {
            return nil
        }

        let recipients = splitAddressList(rawValue)
            .map { resolvedParticipant(from: $0).displayName ?? $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(trimmed)

        guard let firstRecipient = recipients.first else {
            return nil
        }

        guard recipients.count > 1 else {
            return firstRecipient
        }

        return "\(firstRecipient) +\(recipients.count - 1)"
    }

    private static func resolvedPreviewSnippet(from body: String) -> String? {
        let snippet = TextSnippetCreator.createSnippet(
            from: body,
            maxLength: 180,
            firstSentenceOnly: false
        )

        return trimmed(snippet)
    }

    private static func parseForwardedBlock(_ text: String) -> (headers: [String: String], body: String) {
        if !text.contains("\n"),
           let parsedSingleLineBlock = parseSingleLineForwardedBlock(text) {
            return parsedSingleLineBlock
        }

        return parseMultiLineForwardedBlock(text)
    }

    private static func parseSingleLineForwardedBlock(
        _ text: String
    ) -> (headers: [String: String], body: String)? {
        guard let inlineHeaderPattern else {
            return nil
        }

        let matches = inlineHeaderPattern.matches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text)
        )
        guard !matches.isEmpty else {
            return nil
        }

        var headers: [String: String] = [:]
        var orderedHeaderNames: [String] = []

        for index in matches.indices {
            let match = matches[index]
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let fullMatchRange = Range(match.range, in: text) else {
                continue
            }

            let valueStart = fullMatchRange.upperBound
            let valueEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: text) {
                valueEnd = nextRange.lowerBound
            } else {
                valueEnd = text.endIndex
            }

            let headerName = String(text[nameRange]).lowercased()
            let value = String(text[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }

            if let existingValue = headers[headerName], !existingValue.isEmpty {
                headers[headerName] = existingValue + ", " + value
            } else {
                orderedHeaderNames.append(headerName)
                headers[headerName] = value
            }
        }

        guard let lastHeaderName = orderedHeaderNames.last,
              let lastHeaderValue = headers[lastHeaderName] else {
            return nil
        }

        let splitValue = splitTrailingBody(from: lastHeaderValue, headerName: lastHeaderName)
        headers[lastHeaderName] = splitValue.headerValue

        return (headers, splitValue.body)
    }

    private static func splitTrailingBody(
        from rawValue: String,
        headerName: String
    ) -> (headerValue: String, body: String) {
        switch headerName {
        case "date":
            return splitTrailingBodyFromDate(rawValue)
        case "to", "cc":
            return splitTrailingBodyFromRecipientList(rawValue)
        default:
            return (rawValue, "")
        }
    }

    private static func splitTrailingBodyFromDate(_ rawValue: String) -> (headerValue: String, body: String) {
        guard let detector = dateDetector,
              let match = detector.firstMatch(
                in: rawValue,
                options: [],
                range: NSRange(rawValue.startIndex..., in: rawValue)
              ),
              let dateRange = Range(match.range, in: rawValue) else {
            return (rawValue, "")
        }

        let dateValue = trimmed(String(rawValue[dateRange])) ?? rawValue
        let trailingBody = trimmed(String(rawValue[dateRange.upperBound...])) ?? ""
        return (dateValue, trailingBody)
    }

    private static func splitTrailingBodyFromRecipientList(
        _ rawValue: String
    ) -> (headerValue: String, body: String) {
        let tokens = splitAddressList(rawValue)
        guard !tokens.isEmpty else {
            return (rawValue, "")
        }

        var recipients: [String] = []

        for index in tokens.indices {
            let token = tokens[index]
            guard let parsedToken = parseRecipientToken(token) else {
                let remainder = ([token] + Array(tokens.dropFirst(index + 1))).joined(separator: ", ")
                let body = trimmed(remainder) ?? ""
                let headerValue = recipients.joined(separator: ", ")
                return (headerValue.isEmpty ? rawValue : headerValue, body)
            }

            recipients.append(parsedToken.recipient)

            if let remainder = trimmed(parsedToken.remainder) {
                let trailingTokens = Array(tokens.dropFirst(index + 1))
                let body = ([remainder] + trailingTokens).joined(separator: ", ")
                return (recipients.joined(separator: ", "), body)
            }
        }

        return (recipients.joined(separator: ", "), "")
    }

    private static func splitAddressList(_ value: String) -> [String] {
        var tokens: [String] = []
        var currentToken = ""
        var isInsideQuotes = false
        var isEscaped = false
        var angleBracketDepth = 0

        for character in value {
            switch character {
            case "\"":
                if !isEscaped {
                    isInsideQuotes.toggle()
                }
                currentToken.append(character)
                isEscaped = false
            case "\\":
                currentToken.append(character)
                isEscaped.toggle()
            case "<":
                angleBracketDepth += 1
                currentToken.append(character)
                isEscaped = false
            case ">":
                angleBracketDepth = max(0, angleBracketDepth - 1)
                currentToken.append(character)
                isEscaped = false
            case ",":
                if isInsideQuotes || angleBracketDepth > 0 {
                    currentToken.append(character)
                } else if let token = trimmed(currentToken) {
                    tokens.append(token)
                    currentToken.removeAll(keepingCapacity: true)
                } else {
                    currentToken.removeAll(keepingCapacity: true)
                }
                isEscaped = false
            default:
                currentToken.append(character)
                isEscaped = false
            }
        }

        if let token = trimmed(currentToken) {
            tokens.append(token)
        }

        return tokens
    }

    private static func parseRecipientToken(
        _ token: String
    ) -> (recipient: String, remainder: String?)? {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return nil
        }

        if let angleStart = trimmedToken.firstIndex(of: "<"),
           let angleEnd = trimmedToken[angleStart...].firstIndex(of: ">") {
            let recipient = String(trimmedToken[...angleEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(trimmedToken[trimmedToken.index(after: angleEnd)...])
            return (recipient, remainder)
        }

        guard let leadingEmailPattern,
              let match = leadingEmailPattern.firstMatch(
                in: trimmedToken,
                options: [],
                range: NSRange(trimmedToken.startIndex..., in: trimmedToken)
              ),
              let emailRange = Range(match.range, in: trimmedToken) else {
            return nil
        }

        let recipient = String(trimmedToken[emailRange])
        let remainder = String(trimmedToken[emailRange.upperBound...])
        return (recipient, remainder)
    }

    private static func parseMultiLineForwardedBlock(_ text: String) -> (headers: [String: String], body: String) {
        let lines = text.components(separatedBy: .newlines)
        var headers: [String: String] = [:]
        var currentHeaderName: String?
        var currentIndex = 0

        while currentIndex < lines.count {
            let rawLine = lines[currentIndex]
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                if !headers.isEmpty {
                    currentIndex += 1
                    break
                }

                currentIndex += 1
                continue
            }

            if let currentHeaderName,
               rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t") {
                let previousValue = headers[currentHeaderName] ?? ""
                headers[currentHeaderName] = previousValue + " " + trimmedLine
                currentIndex += 1
                continue
            }

            guard let parsedHeader = parseHeaderLine(rawLine) else {
                break
            }

            let existingValue = headers[parsedHeader.name]
            if let existingValue, !existingValue.isEmpty {
                headers[parsedHeader.name] = existingValue + ", " + parsedHeader.value
            } else {
                headers[parsedHeader.name] = parsedHeader.value
            }
            currentHeaderName = parsedHeader.name
            currentIndex += 1
        }

        let body = lines.dropFirst(currentIndex).joined(separator: "\n")
        return (headers, body)
    }

    private static func parseHeaderLine(_ line: String) -> (name: String, value: String)? {
        let lineWithoutNoise: String
        if let leadingHeaderNoisePattern {
            lineWithoutNoise = leadingHeaderNoisePattern.stringByReplacingMatches(
                in: line,
                options: [],
                range: NSRange(line.startIndex..., in: line),
                withTemplate: ""
            )
        } else {
            lineWithoutNoise = line.trimmingCharacters(in: CharacterSet(charactersIn: "-> \t"))
        }

        guard let separatorIndex = lineWithoutNoise.firstIndex(of: ":") else {
            return nil
        }

        let headerName = lineWithoutNoise[..<separatorIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard knownHeaderNames.contains(headerName) else {
            return nil
        }

        let value = String(lineWithoutNoise[lineWithoutNoise.index(after: separatorIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (headerName, value)
    }
}
