import Foundation

/// Reads the bytes of a Gmail attachment from its `attachments.get` response, which arrives as a
/// file (`GmailAPIClient.downloadAttachmentFile`), and writes them to another file, a chunk at a
/// time: the response is never held in memory whole.
///
/// The response is a flat JSON object (`{"attachmentId": "…", "size": 123, "data": "…"}`, in any
/// order) whose `data` is the attachment in base64url. `getAttachment`, which sync's body parts
/// still use, decodes it whole and makes two more copies of the string on the way
/// (`Data(base64UrlEncoded:)`), about four times the attachment in memory; this decodes 64 KB of
/// response at a time into 48 KB of bytes (architecture review 2026-11,
/// attachments-storage-disk#2, networking#2).
///
/// It answers exactly as `Data(base64UrlEncoded:)` does for the strings Gmail sends: the
/// base64url alphabet (and the standard alphabet's `+` and `/`), with or without `=` padding,
/// and the JSON escapes a JSON writer can put in such a string (`\/`, and `=` for `=`, which
/// Google's writers use). Anything else (another escape, a character outside the alphabet, a
/// quartet of one character, `data` that is not a string, no `data`, a response cut short) is an
/// error: the caller maps it to `APIError.invalidData`, and nothing it wrote is kept.
enum GmailAttachmentBodyDecoder {
    enum DecodeError: Error, Equatable {
        /// The object has no `data` field.
        case noDataField
        /// Not the flat JSON object this reads, or `data` is not a string.
        case malformedJSON
        /// `data` holds something that is not base64url.
        case invalidBase64
        /// The response ends before its object does.
        case truncated
    }

    /// Decodes the `data` field of the JSON file at `source` into a new file at `destination`
    /// and returns the number of bytes written. Checks `isCancelled` before each chunk.
    @discardableResult
    static func decodeDataField(
        ofJSONFileAt source: URL,
        into destination: URL,
        chunkSize: Int = 64 * 1024,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var scanner = Scanner()
        var written: Int64 = 0
        let chunkSize = max(1, chunkSize)
        while true {
            if isCancelled() { throw CancellationError() }
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try scanner.consume(chunk)
            if scanner.output.count >= chunkSize {
                try output.write(contentsOf: scanner.output)
                written += Int64(scanner.output.count)
                scanner.output.removeAll(keepingCapacity: true)
            }
        }
        try scanner.finish()
        if !scanner.output.isEmpty {
            try output.write(contentsOf: scanner.output)
            written += Int64(scanner.output.count)
        }
        return written
    }

    /// The JSON object's tokens, with the `data` string decoded as it is read.
    private struct Scanner {
        private enum State {
            case beforeObject
            case expectingKey
            case inKey(escaped: Bool)
            case expectingColon
            case expectingValue
            case inSkippedString(escaped: Bool)
            case inSkippedLiteral
            case inSkippedContainer(depth: Int, inString: Bool, escaped: Bool)
            case inData
            case inDataEscape
            case inDataUnicode(value: UInt32, digits: Int)
            case afterValue
            case done
        }

        private static let dataKey = Array("data".utf8)

        var output: [UInt8] = []
        private var state: State = .beforeObject
        private var key: [UInt8] = []
        private var keyIsData = false
        private var foundData = false
        private var base64 = Base64URLDecoder()

        mutating func consume(_ bytes: Data) throws {
            for byte in bytes {
                try consume(byte)
            }
        }

        mutating func finish() throws {
            guard case .done = state else {
                if case .beforeObject = state { throw DecodeError.malformedJSON }
                throw DecodeError.truncated
            }
            guard foundData else { throw DecodeError.noDataField }
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private mutating func consume(_ byte: UInt8) throws {
            switch state {
            case .beforeObject:
                if Self.isWhitespace(byte) { return }
                guard byte == UInt8(ascii: "{") else { throw DecodeError.malformedJSON }
                state = .expectingKey

            case .expectingKey:
                if Self.isWhitespace(byte) { return }
                if byte == UInt8(ascii: "}") { state = .done; return }
                guard byte == UInt8(ascii: "\"") else { throw DecodeError.malformedJSON }
                key.removeAll(keepingCapacity: true)
                state = .inKey(escaped: false)

            case .inKey(let escaped):
                if escaped {
                    key.append(0)  // an escaped key is never `data`
                    state = .inKey(escaped: false)
                } else if byte == UInt8(ascii: "\\") {
                    state = .inKey(escaped: true)
                } else if byte == UInt8(ascii: "\"") {
                    keyIsData = key == Self.dataKey
                    state = .expectingColon
                } else if key.count <= Self.dataKey.count {
                    key.append(byte)
                }

            case .expectingColon:
                if Self.isWhitespace(byte) { return }
                guard byte == UInt8(ascii: ":") else { throw DecodeError.malformedJSON }
                state = .expectingValue

            case .expectingValue:
                if Self.isWhitespace(byte) { return }
                if keyIsData {
                    guard byte == UInt8(ascii: "\""), !foundData else { throw DecodeError.malformedJSON }
                    base64 = Base64URLDecoder()
                    state = .inData
                } else if byte == UInt8(ascii: "\"") {
                    state = .inSkippedString(escaped: false)
                } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    state = .inSkippedContainer(depth: 1, inString: false, escaped: false)
                } else {
                    state = .inSkippedLiteral
                }

            case .inSkippedString(let escaped):
                if escaped {
                    state = .inSkippedString(escaped: false)
                } else if byte == UInt8(ascii: "\\") {
                    state = .inSkippedString(escaped: true)
                } else if byte == UInt8(ascii: "\"") {
                    state = .afterValue
                }

            case .inSkippedLiteral:
                if byte == UInt8(ascii: ",") {
                    state = .expectingKey
                } else if byte == UInt8(ascii: "}") {
                    state = .done
                }

            case .inSkippedContainer(let depth, let inString, let escaped):
                if inString {
                    if escaped {
                        state = .inSkippedContainer(depth: depth, inString: true, escaped: false)
                    } else if byte == UInt8(ascii: "\\") {
                        state = .inSkippedContainer(depth: depth, inString: true, escaped: true)
                    } else if byte == UInt8(ascii: "\"") {
                        state = .inSkippedContainer(depth: depth, inString: false, escaped: false)
                    }
                } else if byte == UInt8(ascii: "\"") {
                    state = .inSkippedContainer(depth: depth, inString: true, escaped: false)
                } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    state = .inSkippedContainer(depth: depth + 1, inString: false, escaped: false)
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    state = depth == 1
                        ? .afterValue
                        : .inSkippedContainer(depth: depth - 1, inString: false, escaped: false)
                }

            case .inData:
                if byte == UInt8(ascii: "\"") {
                    try base64.finish(into: &output)
                    foundData = true
                    state = .afterValue
                } else if byte == UInt8(ascii: "\\") {
                    state = .inDataEscape
                } else {
                    try base64.feed(byte, into: &output)
                }

            case .inDataEscape:
                switch byte {
                case UInt8(ascii: "/"):
                    try base64.feed(byte, into: &output)
                    state = .inData
                case UInt8(ascii: "u"):
                    state = .inDataUnicode(value: 0, digits: 0)
                default:
                    // `\\`, `\"`, `\n` and the rest are JSON, never base64url.
                    throw DecodeError.invalidBase64
                }

            case .inDataUnicode(let value, let digits):
                guard let digit = Self.hexValue(byte) else { throw DecodeError.malformedJSON }
                let next = value << 4 | digit
                if digits == 3 {
                    guard next < 0x80 else { throw DecodeError.invalidBase64 }
                    try base64.feed(UInt8(next), into: &output)
                    state = .inData
                } else {
                    state = .inDataUnicode(value: next, digits: digits + 1)
                }

            case .afterValue:
                if Self.isWhitespace(byte) { return }
                if byte == UInt8(ascii: ",") {
                    state = .expectingKey
                } else if byte == UInt8(ascii: "}") {
                    state = .done
                } else {
                    throw DecodeError.malformedJSON
                }

            case .done:
                if Self.isWhitespace(byte) { return }
                throw DecodeError.malformedJSON
            }
        }

        private static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
    }

    /// Base64url, a character at a time, as `Data(base64UrlEncoded:)` reads it: both alphabets'
    /// two last characters, padding optional, and a last quartet of two or three characters.
    private struct Base64URLDecoder {
        private var bits: UInt32 = 0
        private var pending = 0
        private var padding = 0

        mutating func feed(_ byte: UInt8, into output: inout [UInt8]) throws {
            if byte == UInt8(ascii: "=") {
                guard pending >= 2, pending + padding < 4 else { throw DecodeError.invalidBase64 }
                padding += 1
                return
            }
            guard padding == 0, let value = Self.sextet(byte) else { throw DecodeError.invalidBase64 }
            bits = bits << 6 | value
            pending += 1
            if pending == 4 {
                output.append(UInt8(truncatingIfNeeded: bits >> 16))
                output.append(UInt8(truncatingIfNeeded: bits >> 8))
                output.append(UInt8(truncatingIfNeeded: bits))
                bits = 0
                pending = 0
            }
        }

        mutating func finish(into output: inout [UInt8]) throws {
            switch pending {
            case 0:
                guard padding == 0 else { throw DecodeError.invalidBase64 }
            case 2:
                output.append(UInt8(truncatingIfNeeded: bits >> 4))
            case 3:
                guard padding <= 1 else { throw DecodeError.invalidBase64 }
                output.append(UInt8(truncatingIfNeeded: bits >> 10))
                output.append(UInt8(truncatingIfNeeded: bits >> 2))
            default:
                throw DecodeError.invalidBase64
            }
        }

        private static func sextet(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt32(byte - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt32(byte - UInt8(ascii: "a") + 26)
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0") + 52)
            case UInt8(ascii: "-"), UInt8(ascii: "+"): return 62
            case UInt8(ascii: "_"), UInt8(ascii: "/"): return 63
            default: return nil
            }
        }
    }
}
