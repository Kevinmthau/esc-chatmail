import Foundation

/// Decodes RFC 2047 encoded-words ("=?charset?B?...?=" / "=?charset?Q?...?=")
/// that appear in message header values.
///
/// Gmail's API usually hands back header values already decoded to UTF-8, but
/// raw encoded words still reach us — malformed messages the API passes
/// through verbatim, and headers parsed out of raw RFC 822 source. Undecoded
/// words render as garbage in sender names and subjects.
enum RFC2047Decoder {

    /// Cheap pre-check so callers can skip regex work for the common case.
    /// Matches the "=?" opener plus a later "?=" closer; false positives are
    /// harmless because `decode` leaves non-matching text untouched.
    static func containsEncodedWord(_ value: String) -> Bool {
        guard let openRange = value.range(of: "=?") else { return false }
        return value.range(of: "?=", range: openRange.upperBound..<value.endIndex) != nil
    }

    /// Decodes every well-formed encoded-word in the value, leaving anything
    /// undecodable exactly as it appeared. Linear whitespace BETWEEN two
    /// encoded words is dropped (RFC 2047 §6.2); whitespace between an
    /// encoded word and ordinary text is preserved.
    static func decode(_ value: String) -> String {
        guard containsEncodedWord(value) else { return value }

        let nsValue = value as NSString
        let matches = encodedWordRegex.matches(
            in: value,
            range: NSRange(location: 0, length: nsValue.length)
        )
        guard !matches.isEmpty else { return value }

        var output = ""
        var cursor = 0
        // Adjacent same-charset words accumulate raw bytes before charset
        // decoding: senders split multibyte characters across encoded words,
        // so decoding word-by-word would corrupt the split character.
        var pendingBytes = Data()
        var pendingCharset: String?
        var previousWasDecodedWord = false

        func flushPending() {
            guard let charset = pendingCharset else { return }
            output += decodeBytes(pendingBytes, charset: charset)
            pendingBytes = Data()
            pendingCharset = nil
        }

        for match in matches {
            let separator = nsValue.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let separatorIsBlank = separator.unicodeScalars.allSatisfy {
                $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
            }

            let charset = normalizedCharset(nsValue.substring(with: match.range(at: 1)))
            let encodingKind = nsValue.substring(with: match.range(at: 2)).uppercased()
            let encodedText = nsValue.substring(with: match.range(at: 3))

            let wordBytes: Data?
            switch encodingKind {
            case "B":
                wordBytes = decodeBase64(encodedText)
            case "Q":
                wordBytes = decodeQ(encodedText)
            default:
                wordBytes = nil
            }

            if let wordBytes {
                let joinsPendingRun = pendingCharset != nil
                    && pendingCharset == charset
                    && separatorIsBlank
                if !joinsPendingRun {
                    flushPending()
                    // Whitespace between two encoded words disappears (§6.2);
                    // any other separator text is real content.
                    if !(separatorIsBlank && previousWasDecodedWord) {
                        output += separator
                    }
                    pendingCharset = charset
                }
                pendingBytes.append(wordBytes)
                previousWasDecodedWord = true
            } else {
                // Undecodable word: keep the surrounding text and the word
                // itself verbatim rather than guessing.
                flushPending()
                output += separator + nsValue.substring(with: match.range)
                previousWasDecodedWord = false
            }

            cursor = match.range.location + match.range.length
        }

        flushPending()
        output += nsValue.substring(from: cursor)
        return output
    }

    // MARK: - Internals

    /// encoded-word := "=?" charset ["*" language] "?" encoding "?" encoded-text "?="
    /// charset and encoded-text never contain "?" or whitespace.
    private static let encodedWordRegex: NSRegularExpression = {
        let pattern = #"=\?([^?\s]+)\?([A-Za-z])\?([^?\s]*)\?="#
        // The pattern is a compile-time constant; force-try is safe.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Strips the optional RFC 2231 language tag ("utf-8*en" → "utf-8") and
    /// lowercases for comparison/grouping.
    private static func normalizedCharset(_ raw: String) -> String {
        let base = raw.split(separator: "*", maxSplits: 1).first.map(String.init) ?? raw
        return base.lowercased()
    }

    private static func decodeBase64(_ text: String) -> Data? {
        guard !text.isEmpty else { return Data() }
        // Some senders omit base64 padding; restore it before decoding.
        let remainder = text.count % 4
        let padded = remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded)
    }

    private static func decodeQ(_ text: String) -> Data? {
        var bytes = Data()
        bytes.reserveCapacity(text.utf8.count)
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "_"):
                bytes.append(0x20)
            case UInt8(ascii: "="):
                guard let high = iterator.next(), let low = iterator.next(),
                      let highValue = hexValue(high), let lowValue = hexValue(low) else {
                    return nil
                }
                bytes.append(highValue << 4 | lowValue)
            default:
                bytes.append(byte)
            }
        }
        return bytes
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    private static func decodeBytes(_ bytes: Data, charset: String) -> String {
        if let encoding = stringEncoding(forCharset: charset),
           let decoded = String(data: bytes, encoding: encoding) {
            return decoded
        }
        // Fallback chain: most mislabeled headers are really UTF-8, and
        // Latin-1 maps every byte so it always yields something readable.
        if let utf8 = String(data: bytes, encoding: .utf8) {
            return utf8
        }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func stringEncoding(forCharset charset: String) -> String.Encoding? {
        // Common cases first so the CF round-trip is rarely needed.
        switch charset {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default:
            break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
