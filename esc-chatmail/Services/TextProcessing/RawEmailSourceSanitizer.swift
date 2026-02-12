import Foundation

/// Extracts displayable message content from raw email source blobs.
/// Some messages can arrive as full RFC822 source (transport headers + MIME boundaries),
/// which should never be shown directly in chat bubbles.
enum RawEmailSourceSanitizer {
    private static let minimumHeaderLinesForRawSource = 5

    private static let mimeHeaderPrefixes: [String] = [
        "content-type:",
        "content-transfer-encoding:",
        "content-disposition:",
        "content-id:",
        "content-description:",
        "x-attachment-id:",
        "mime-version:"
    ]

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

    private static let boundaryPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"boundary\s*=\s*(?:"([^"]+)"|([^\s;]+))"#,
            options: [.caseInsensitive]
        )
    }()

    static func extractDisplayText(from text: String) -> String {
        let normalized = normalizeLineEndings(text)
        guard looksLikeRawEmailSource(normalized) else { return normalized }

        let withoutTransportHeaders = stripLeadingTransportHeaders(from: normalized)

        if let plainPart = extractPlainTextPart(from: withoutTransportHeaders), !plainPart.isEmpty {
            return plainPart
        }

        return stripMimeScaffolding(from: withoutTransportHeaders)
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func looksLikeRawEmailSource(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let topHeaderCount = countLeadingHeaderLines(in: lines)
        guard topHeaderCount >= minimumHeaderLinesForRawSource else { return false }

        let lower = text.lowercased()
        if lower.contains("content-type: multipart/") {
            return true
        }

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
        let lines = text.components(separatedBy: .newlines)
        let boundary = extractBoundary(from: text)

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let lower = line.lowercased()

            guard lower.hasPrefix("content-type:"),
                  lower.contains("text/plain") else {
                index += 1
                continue
            }

            var partHeaders: [String] = [line]
            var bodyStart = index + 1

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

                break
            }

            var bodyLines: [String] = []
            var cursor = bodyStart

            while cursor < lines.count {
                let bodyLine = lines[cursor]
                if isBoundaryLine(bodyLine, boundary: boundary) {
                    break
                }
                bodyLines.append(bodyLine)
                cursor += 1
            }

            var body = bodyLines.joined(separator: "\n")
            body = decodePartBodyIfNeeded(body, headers: partHeaders)
            body = stripMimeScaffolding(from: body)
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)

            if !body.isEmpty {
                return body
            }

            index = cursor + 1
        }

        return nil
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

            if isBoundaryLine(trimmed, boundary: boundary) {
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

        return token.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" ||
            character == "." || character == ":" || character == "="
        }
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
