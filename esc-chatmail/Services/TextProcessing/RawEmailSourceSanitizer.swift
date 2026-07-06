import Foundation

/// Extracts displayable message content from raw email source blobs.
/// Some messages can arrive as full RFC822 source (transport headers + MIME boundaries),
/// which should never be shown directly in chat bubbles.
enum RawEmailSourceSanitizer {
    private static let minimumHeaderLinesForRawSource = 5

    private static let mimeHeaderPrefixes = MIMEPatterns.headerPrefixes

    private static let transportMarkers: [String] = [
        "delivered-to:",
        "return-path:",
        "\nreceived:",
        "x-received:",
        "arc-seal:",
        "arc-authentication-results:",
        "authentication-results:",
        "dkim-signature:",
        "x-google-dkim-signature:"
    ]

    private static let boundaryPattern = MIMEPatterns.boundary

    static func extractDisplayText(from text: String) -> String {
        let normalized = normalizeLineEndings(text)
        guard looksLikeRawEmailSource(normalized) else { return normalized }

        let withoutTransportHeaders = stripLeadingTransportHeaders(from: normalized)

        if let plainPart = extractPlainTextPart(from: withoutTransportHeaders), !plainPart.isEmpty {
            return plainPart
        }

        return stripMimeScaffolding(from: withoutTransportHeaders)
    }

    /// Outcome of attempting to pull an HTML part out of a raw email blob.
    /// Distinguishes "not raw source at all" from "raw source but no HTML part" so
    /// callers can gate telemetry/recovery on a single parse instead of first
    /// calling a detection predicate and then re-normalizing for extraction.
    enum RawHTMLExtraction: Equatable {
        case notRawSource
        case rawSourceWithoutHTML
        case html(String)
    }

    static func extractHTMLResult(from text: String) -> RawHTMLExtraction {
        let normalized = normalizeLineEndings(text)
        guard looksLikeRawEmailSource(normalized) else { return .notRawSource }

        let withoutTransportHeaders = stripLeadingTransportHeaders(from: normalized)
        guard let htmlPart = extractPartBody(
            from: withoutTransportHeaders,
            matchingContentType: { lower in
                lower.hasPrefix("content-type:") && lower.contains("text/html")
            },
            stripScaffoldingAfterDecode: false
        ) else {
            return .rawSourceWithoutHTML
        }

        let trimmed = htmlPart.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .rawSourceWithoutHTML : .html(trimmed)
    }

    static func extractHTMLText(from text: String) -> String? {
        if case .html(let html) = extractHTMLResult(from: text) {
            return html
        }
        return nil
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        TextProcessing.normalizeLineEndings(text)
    }

    private static func looksLikeRawEmailSource(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let topHeaderCount = countLeadingHeaderLines(in: lines)
        let lower = text.lowercased()
        let hasMultipartContentType = lower.contains("content-type: multipart/")
        if hasMultipartContentType,
           topHeaderCount >= 1,
           extractBoundary(from: text) != nil {
            return true
        }

        guard topHeaderCount >= minimumHeaderLinesForRawSource else { return false }

        return transportMarkers.contains { lower.contains($0) }
    }

    private static func countLeadingHeaderLines(in lines: [String]) -> Int {
        var count = 0

        for line in lines.prefix(80) {
            if line.isEmpty {
                break
            }

            if isHeaderLine(line) || line.hasPrefix(" ") || line.hasPrefix("\t") {
                if isHeaderLine(line) {
                    count += 1
                }
                continue
            }

            break
        }

        return count
    }

    private static func stripLeadingTransportHeaders(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var headerCount = 0
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.isEmpty {
                if headerCount >= minimumHeaderLinesForRawSource {
                    let bodyStart = index + 1
                    guard bodyStart < lines.count else { return "" }
                    return lines[bodyStart...].joined(separator: "\n")
                }
                return text
            }

            if isHeaderLine(line) {
                headerCount += 1
                index += 1
                continue
            }

            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                index += 1
                continue
            }

            return text
        }

        return text
    }

    private static func extractPlainTextPart(from text: String) -> String? {
        extractPartBody(
            from: text,
            matchingContentType: { lower in
                lower.hasPrefix("content-type:") && lower.contains("text/plain")
            },
            stripScaffoldingAfterDecode: true
        )
    }

    private static func extractPartBody(
        from text: String,
        matchingContentType: (String) -> Bool,
        stripScaffoldingAfterDecode: Bool
    ) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let boundary = extractBoundary(from: text)
        let knownBoundaries = extractKnownBoundaries(from: text)

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.isEmpty ||
                isAnyBoundaryLine(trimmed, preferredBoundary: boundary, knownBoundaries: knownBoundaries) ||
                !isHeaderLine(line) {
                index += 1
                continue
            }

            var partHeaders: [String] = []
            var bodyStart = index

            while bodyStart < lines.count {
                let headerLine = lines[bodyStart]
                if headerLine.isEmpty {
                    bodyStart += 1
                    break
                }

                if headerLine.hasPrefix(" ") || headerLine.hasPrefix("\t") || isHeaderLine(headerLine) {
                    partHeaders.append(headerLine)
                    bodyStart += 1
                    continue
                }

                partHeaders.removeAll()
                break
            }

            guard !partHeaders.isEmpty,
                  unfoldedHeaderLines(partHeaders)
                .map({ $0.lowercased() })
                .contains(where: matchingContentType) else {
                index = max(bodyStart, index + 1)
                continue
            }

            var bodyLines: [String] = []
            var cursor = bodyStart

            while cursor < lines.count {
                let bodyLine = lines[cursor]
                if isAnyBoundaryLine(bodyLine, preferredBoundary: boundary, knownBoundaries: knownBoundaries) {
                    break
                }
                bodyLines.append(bodyLine)
                cursor += 1
            }

            var body = bodyLines.joined(separator: "\n")
            body = decodePartBodyIfNeeded(body, headers: partHeaders)
            if stripScaffoldingAfterDecode || containsEmbeddedMimeScaffolding(body) {
                body = stripMimeScaffolding(from: body)
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)

            if !body.isEmpty {
                return body
            }

            index = cursor + 1
        }

        return nil
    }

    private static func unfoldedHeaderLines(_ headers: [String]) -> [String] {
        var unfolded: [String] = []

        for header in headers {
            if header.hasPrefix(" ") || header.hasPrefix("\t") {
                if let last = unfolded.indices.last {
                    unfolded[last] += " " + header.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    unfolded.append(header.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continue
            }

            unfolded.append(header)
        }

        return unfolded
    }

    private static func containsEmbeddedMimeScaffolding(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("\ncontent-type:") ||
            lower.contains("\ncontent-transfer-encoding:") ||
            lower.contains("\ncontent-disposition:") ||
            lower.contains("\n--")
    }

    private static func decodePartBodyIfNeeded(_ body: String, headers: [String]) -> String {
        let lowerHeaders = headers.joined(separator: "\n").lowercased()

        if lowerHeaders.contains("quoted-printable") {
            return QuotedPrintableDecoder.decode(body)
        }

        if lowerHeaders.contains("base64"), let decoded = decodeBase64Text(body) {
            return decoded
        }

        return body
    }

    private static func decodeBase64Text(_ text: String) -> String? {
        let compact = text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard !compact.isEmpty else { return nil }

        let remainder = compact.count % 4
        let padded = remainder == 0 ? compact : compact + String(repeating: "=", count: 4 - remainder)

        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stripMimeScaffolding(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let boundary = extractBoundary(from: text)
        let knownBoundaries = extractKnownBoundaries(from: text)

        var cleanedLines: [String] = []
        var skipContinuationLine = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if skipContinuationLine {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    continue
                }
                skipContinuationLine = false
            }

            if isAnyBoundaryLine(trimmed, preferredBoundary: boundary, knownBoundaries: knownBoundaries) {
                continue
            }

            if mimeHeaderPrefixes.contains(where: { lower.hasPrefix($0) }) {
                skipContinuationLine = true
                continue
            }

            cleanedLines.append(line)
        }

        return cleanedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractBoundary(from text: String) -> String? {
        guard let regex = boundaryPattern else { return nil }
        let headerRegion = text.components(separatedBy: .newlines).prefix(120).joined(separator: "\n")
        let range = NSRange(location: 0, length: headerRegion.utf16.count)

        guard let match = regex.firstMatch(in: headerRegion, options: [], range: range) else {
            return nil
        }

        if match.numberOfRanges > 1,
           let quotedRange = Range(match.range(at: 1), in: headerRegion),
           !quotedRange.isEmpty {
            return String(headerRegion[quotedRange])
        }

        if match.numberOfRanges > 2,
           let unquotedRange = Range(match.range(at: 2), in: headerRegion),
           !unquotedRange.isEmpty {
            return String(headerRegion[unquotedRange])
        }

        return nil
    }

    private static func extractKnownBoundaries(from text: String) -> Set<String> {
        guard let regex = boundaryPattern else { return [] }
        let lines = text.components(separatedBy: .newlines)
        let headerRegion = lines.prefix(240).joined(separator: "\n")
        let range = NSRange(location: 0, length: headerRegion.utf16.count)
        let matches = regex.matches(in: headerRegion, options: [], range: range)

        var boundaries: Set<String> = []
        for match in matches {
            if match.numberOfRanges > 1,
               let quotedRange = Range(match.range(at: 1), in: headerRegion),
               !quotedRange.isEmpty {
                boundaries.insert(String(headerRegion[quotedRange]))
                continue
            }

            if match.numberOfRanges > 2,
               let unquotedRange = Range(match.range(at: 2), in: headerRegion),
               !unquotedRange.isEmpty {
                boundaries.insert(String(headerRegion[unquotedRange]))
            }
        }

        // Fallback for raw-source blobs where top-level Content-Type headers were stripped.
        // Real MIME boundaries repeat multiple times; body separators usually do not.
        var boundaryCounts: [String: Int] = [:]
        for (index, line) in lines.prefix(320).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let token = boundaryToken(from: trimmed),
                  isLikelyFallbackBoundaryLine(at: index, in: lines, token: token) else {
                continue
            }
            boundaryCounts[token, default: 0] += 1
        }

        for (token, count) in boundaryCounts where count >= 2 {
            boundaries.insert(token)
        }

        return boundaries
    }

    private static func isBoundaryLine(_ line: String, boundary: String?) -> Bool {
        guard line.hasPrefix("--") else { return false }

        if let boundary {
            return line.hasPrefix("--\(boundary)")
        }

        var token = String(line.dropFirst(2))
        if token.hasSuffix("--") {
            token = String(token.dropLast(2))
        }

        guard token.count >= 12 else { return false }

        return token.allSatisfy(isValidBoundaryCharacter(_:))
    }

    private static func boundaryToken(from line: String) -> String? {
        guard line.hasPrefix("--") else { return nil }

        var token = String(line.dropFirst(2))
        if token.hasSuffix("--") {
            token = String(token.dropLast(2))
        }

        guard token.count >= 6 else { return nil }
        guard token.allSatisfy(isValidFallbackBoundaryCharacter(_:)) else {
            return nil
        }

        return token
    }

    private static func isLikelyFallbackBoundaryLine(
        at index: Int,
        in lines: [String],
        token: String
    ) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed == "--\(token)--" {
            return true
        }

        var cursor = index + 1
        while cursor < lines.count {
            let nextLine = lines[cursor]
            if nextLine.isEmpty {
                cursor += 1
                continue
            }

            return isHeaderLine(nextLine)
        }

        return false
    }

    private static func isValidFallbackBoundaryCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "()+_-./:=?".contains(character)
    }

    private static func isValidBoundaryCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "'()+_,-./:=?".contains(character)
    }

    private static func isAnyBoundaryLine(
        _ line: String,
        preferredBoundary: String?,
        knownBoundaries: Set<String>
    ) -> Bool {
        if let preferredBoundary, isBoundaryLine(line, boundary: preferredBoundary) {
            return true
        }

        for boundary in knownBoundaries where boundary != preferredBoundary {
            if isBoundaryLine(line, boundary: boundary) {
                return true
            }
        }

        return false
    }

    private static func isHeaderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(of: ":"), separator > trimmed.startIndex else {
            return false
        }

        let fieldName = trimmed[..<separator]
        return fieldName.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-"
        }
    }
}
