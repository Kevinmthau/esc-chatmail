import Foundation

// MARK: - Log Redaction

/// Helpers that strip personally identifiable information (PII) from values
/// before they are interpolated into a log message.
///
/// The logging pipeline writes a fully-formed Swift `String` to the unified log
/// as `%{public}@` (see `Log.log(level:message:...)`). OSLog can only redact
/// values that are passed to it as discrete format arguments — it cannot redact
/// PII that is already baked into a runtime string. Redaction therefore has to
/// happen at the call site, before interpolation.
///
/// Route any email address, sender/recipient header, or URL through these
/// helpers so logs stay useful for debugging without persisting PII to the
/// device log / sysdiagnose.
extension Log {

    /// Masks an email address, preserving the first character of the local part
    /// and the full domain so logs remain debuggable (which provider / roughly
    /// which account) without exposing the address.
    ///
    /// - `"jane.doe@example.com"` → `"j***@example.com"`
    /// - `"a@example.com"` → `"***@example.com"` (single-character local parts
    ///   are masked entirely so they aren't revealed)
    /// - values without an `@` are fully masked, since they aren't emails
    static func redact(email: String?) -> String {
        guard let email, !email.isEmpty else { return "<none>" }
        guard let atIndex = email.lastIndex(of: "@") else { return "<redacted>" }

        let local = email[..<atIndex]
        let domain = email[email.index(after: atIndex)...]

        let maskedLocal: String
        if let first = local.first, local.count >= 2 {
            maskedLocal = "\(first)***"
        } else {
            maskedLocal = "***"
        }

        return domain.isEmpty ? maskedLocal : "\(maskedLocal)@\(domain)"
    }

    /// Masks the email inside a sender/recipient header value, dropping the
    /// display name (also PII).
    ///
    /// - `"Jane Doe <jane@example.com>"` → `"j***@example.com"`
    /// - values with no parseable email are fully masked
    static func redact(address headerValue: String?) -> String {
        guard let headerValue, !headerValue.isEmpty else { return "<none>" }
        if let email = EmailNormalizer.extractEmail(from: headerValue),
           isCompleteEmailAddress(email) {
            return redact(email: email)
        }
        return "<redacted>"
    }

    private static func isCompleteEmailAddress(_ email: String) -> Bool {
        EmailNormalizer.extractEmail(from: email) == email
    }

    /// Reduces a URL to scheme + host, dropping the path, query, and fragment,
    /// which can carry tokens or other sensitive data. Hostless URLs (e.g.
    /// `file:`, `cid:`, `mailto:`) collapse to just their scheme so local paths
    /// — which may themselves encode PII — are never logged.
    ///
    /// - `"https://example.com/reset?token=abc"` → `"https://example.com/..."`
    /// - `"https://example.com"` → `"https://example.com"`
    /// - `"file:///var/mobile/.../avatar.jpg"` → `"file:..."`
    static func redact(url: URL?) -> String {
        guard let url else { return "<none>" }
        let scheme = url.scheme ?? "?"

        guard let host = url.host, !host.isEmpty else {
            return "\(scheme):..."
        }

        let hasDetail = !(url.path.isEmpty || url.path == "/")
            || url.query != nil
            || url.fragment != nil
        return hasDetail ? "\(scheme)://\(host)/..." : "\(scheme)://\(host)"
    }

    /// String overload of `redact(url:)`. Values that don't parse as a URL are
    /// fully masked rather than logged verbatim.
    static func redact(url string: String?) -> String {
        guard let string, !string.isEmpty else { return "<none>" }
        guard let url = URL(string: string) else { return "<redacted-url>" }
        return redact(url: url)
    }
}
