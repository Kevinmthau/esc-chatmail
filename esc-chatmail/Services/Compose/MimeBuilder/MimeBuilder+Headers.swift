import Foundation

// MARK: - Header Formatting & Encoding
extension MimeBuilder {
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    static func generateMessageId() -> String {
        let uuid = UUID().uuidString.lowercased()
        let bundleId = Bundle.main.bundleIdentifier ?? "com.app.mail"
        let domain = bundleId.replacingOccurrences(of: ".", with: "-")
        return "<\(uuid)@\(domain)>"
    }

    /// Stable RFC Message-ID used to reconcile an ambiguous non-idempotent send.
    /// Hex encoding is injection-safe and preserves the optimistic ID exactly.
    static func messageId(forOptimisticMessageID optimisticMessageID: String) -> String {
        let localPart = optimisticMessageID.utf8
            .map { String(format: "%02x", $0) }
            .joined()
        let bundleId = Bundle.main.bundleIdentifier ?? "com.app.mail"
        let domain = bundleId.replacingOccurrences(of: ".", with: "-")
        return "<esc-\(localPart)@\(domain)>"
    }

    static func optimisticMessageID(from rfcMessageId: String) -> String? {
        guard rfcMessageId.hasPrefix("<esc-"),
              let atIndex = rfcMessageId.firstIndex(of: "@") else {
            return nil
        }
        let hexStart = rfcMessageId.index(rfcMessageId.startIndex, offsetBy: 5)
        let hex = rfcMessageId[hexStart..<atIndex]
        guard !hex.isEmpty,
              hex.count <= 256,
              hex.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        guard let optimisticMessageID = String(bytes: bytes, encoding: .utf8),
              messageId(forOptimisticMessageID: optimisticMessageID) == rfcMessageId else {
            return nil
        }
        return optimisticMessageID
    }

    /// Sanitizes header values to prevent CRLF injection attacks.
    ///
    /// `options: .literal` is load-bearing: the default `replacingOccurrences`
    /// matches by canonical/grapheme equivalence, so a CR or LF that is the base
    /// of a combining sequence (e.g. LF + U+0301) forms one grapheme cluster and
    /// is NOT matched — the newline survives and can inject a header line.
    /// `.literal` forces exact scalar matching so every CR/LF is collapsed.
    static func sanitizeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ", options: .literal)
            .replacingOccurrences(of: "\r", with: " ", options: .literal)
            .replacingOccurrences(of: "\n", with: " ", options: .literal)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Escapes a value for interpolation inside a quoted MIME parameter string
    /// (`name="…"` / `filename="…"`). CRLF sanitization alone is insufficient in
    /// that position: a double-quote in the value terminates the quoted-string
    /// early and smuggles extra parameters into the part header. Backslashes are
    /// escaped first so a trailing bare backslash cannot turn the closing quote
    /// into a quoted-pair and swallow the rest of the header line.
    /// `formatFromHeader`'s quoted display-name path delegates here (RFC 5322
    /// quoted-string and RFC 2045 quoted-parameter share the same quoted-pair
    /// grammar), so the escape order has one owner and cannot drift.
    ///
    /// `options: .literal` mirrors sanitizeHeaderValue: without it a quote or
    /// backslash that is the base of a combining sequence is one grapheme and
    /// escapes unmatched, reopening the very quoted-string breakout this closes.
    ///
    /// Non-ASCII stays raw UTF-8 inside the quoted string (matching the web
    /// builder): strictly RFC 2045 headers are ASCII and RFC 2231 `filename*=`
    /// is the conformant spell, but Gmail accepts the 8-bit form and echoes the
    /// same bytes back, which keeps the attachment fingerprint stable. If a
    /// receiving client mangles such a name, RFC 2231 is the fix — as its own
    /// change, on both platforms.
    static func quoteParameterValue(_ value: String) -> String {
        sanitizeHeaderValue(value)
            .replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "\"", with: "\\\"", options: .literal)
    }

    /// RFC 2045 token characters, used to validate a media type's `type/subtype`.
    private static let mimeTypeTokenScalars: Set<Unicode.Scalar> =
        Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".unicodeScalars)

    /// Narrows a media type to `type/subtype` of RFC 2045 tokens, falling back to
    /// `application/octet-stream`. The media type is interpolated UNQUOTED ahead
    /// of `name="…"`, so without this a crafted type (`image/png; boundary="…"`)
    /// adds parameters to — or unbalances the quoting of — the part header the
    /// filename escaping protects. Case is preserved: media types are
    /// case-insensitive, but the attachment echo fingerprint compares bytes, so
    /// a legitimate type must not be rewritten.
    static func sanitizeMimeType(_ mimeType: String) -> String {
        let sanitized = sanitizeHeaderValue(mimeType)
        guard let slashIndex = sanitized.firstIndex(of: "/") else {
            return "application/octet-stream"
        }
        let type = sanitized[sanitized.startIndex..<slashIndex]
        let subtype = sanitized[sanitized.index(after: slashIndex)...]
        guard isMimeTypeToken(type), isMimeTypeToken(subtype) else {
            return "application/octet-stream"
        }
        return "\(type)/\(subtype)"
    }

    private static func isMimeTypeToken(_ token: Substring) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { mimeTypeTokenScalars.contains($0) }
    }

    /// Strips angle brackets and whitespace from a Content-ID body. The builder
    /// supplies the `<…>` delimiters, so an interior `<`/`>` (which survives
    /// sanitizeHeaderValue, since it only removes CR/LF) would nest or prematurely
    /// close them and malform the msg-id. Returns "" when nothing usable remains,
    /// so the caller can omit the header rather than emit `<>`.
    static func sanitizeContentId(_ contentId: String) -> String {
        let disallowed = CharacterSet(charactersIn: "<>").union(.whitespacesAndNewlines)
        let scalars = sanitizeHeaderValue(contentId).unicodeScalars.filter { !disallowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A non-empty attachment filename for the quoted `name=`/`filename=`
    /// parameters. An unnamed part is effectively undownloadable, so an empty or
    /// whitespace-only name falls back to "attachment" (matching the web builder).
    static func sanitizeAttachmentFilename(_ filename: String) -> String {
        let sanitized = sanitizeHeaderValue(filename)
        return sanitized.isEmpty ? "attachment" : sanitized
    }

    /// Emits the header block for one attachment MIME part — Content-Type through
    /// the blank line before the base64 body — routing every interpolated value
    /// through the sanitizer its position requires, so no call site can
    /// reintroduce the quoted-parameter or unquoted-token injection classes by
    /// hand. `contentId == nil` → a regular attachment part (Content-Disposition:
    /// attachment); non-nil → an inline part (Content-ID + Content-Disposition:
    /// inline). A Content-ID that sanitizes to empty is omitted rather than
    /// emitted as a malformed `<>`.
    static func attachmentPartHeaders(mimeType: String, filename: String, contentId: String?) -> String {
        let safeMimeType = sanitizeMimeType(mimeType)
        let safeFilename = quoteParameterValue(sanitizeAttachmentFilename(filename))

        var headers = "Content-Type: \(safeMimeType); name=\"\(safeFilename)\"\r\n"
        headers += "Content-Transfer-Encoding: base64\r\n"
        if let contentId {
            let safeContentId = sanitizeContentId(contentId)
            if !safeContentId.isEmpty {
                headers += "Content-ID: <\(safeContentId)>\r\n"
            }
            headers += "Content-Disposition: inline; filename=\"\(safeFilename)\"\r\n"
        } else {
            headers += "Content-Disposition: attachment; filename=\"\(safeFilename)\"\r\n"
        }
        headers += "\r\n"
        return headers
    }

    static func encodeHeaderIfNeeded(_ text: String) -> String {
        let sanitized = sanitizeHeaderValue(text)
        let asciiOnly = sanitized.unicodeScalars.allSatisfy { $0.isASCII }
        if asciiOnly {
            return sanitized
        }

        guard let data = sanitized.data(using: .utf8) else { return sanitized }
        let base64 = data.base64EncodedString()
        return "=?UTF-8?B?\(base64)?="
    }

    static func formatFromHeader(email: String, name: String?) -> String {
        let sanitizedEmail = sanitizeHeaderValue(email)
        guard let name = name, !name.isEmpty else {
            return sanitizedEmail
        }

        // Check if name needs encoding for non-ASCII characters
        let encodedName = encodeHeaderIfNeeded(name)

        // Format as "Name <email@example.com>". If the name contains a special,
        // quote it and escape via quoteParameterValue (the shared quoted-string
        // escaper: sanitize CRLF, then backslashes, then quotes). Backslash is in
        // the trigger set because a bare backslash in an unquoted phrase is
        // RFC 5322-invalid, so it must take the quoted/escaped path too.
        if name.contains(where: { $0 == "\"" || $0 == "\\" || $0 == "<" || $0 == ">" || $0 == "," || $0 == "@" }) {
            return "\"\(quoteParameterValue(name))\" <\(sanitizedEmail)>"
        } else {
            return "\(encodedName) <\(sanitizedEmail)>"
        }
    }
}
