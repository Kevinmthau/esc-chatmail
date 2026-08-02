import Foundation

class EmailNormalizer {
    static func normalize(_ email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard let atIndex = trimmed.firstIndex(of: "@") else {
            return trimmed
        }
        
        let localPart = String(trimmed[..<atIndex])
        let domain = String(trimmed[trimmed.index(after: atIndex)...])
        
        if domain == "gmail.com" || domain == "googlemail.com" {
            var normalizedLocal = localPart.replacingOccurrences(of: ".", with: "")
            
            if let plusIndex = normalizedLocal.firstIndex(of: "+") {
                normalizedLocal = String(normalizedLocal[..<plusIndex])
            }
            
            return "\(normalizedLocal)@gmail.com"
        }
        
        return trimmed
    }
    
    /// Returns true if the email is a Gmail address (gmail.com or googlemail.com)
    static func isGmailAddress(_ email: String) -> Bool {
        let lowercased = email.lowercased()
        return lowercased.hasSuffix("@gmail.com") || lowercased.hasSuffix("@googlemail.com")
    }

    static func extractEmail(from string: String) -> String? {
        let pattern = #"<([^>]+@[^>]+)>"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
           let range = Range(match.range(at: 1), in: string) {
            return String(string[range])
        }

        if let match = firstBareEmailMatch(in: string) {
            return match.email
        }
        
        return nil
    }
    
    static func extractAllEmails(from string: String) -> [String] {
        var emails: [String] = []
        
        // Split by comma to handle multiple recipients
        let recipients = string.split(separator: ",")
        
        for recipient in recipients {
            let recipientStr = String(recipient).trimmingCharacters(in: .whitespacesAndNewlines)

            if let email = extractEmail(from: recipientStr) {
                emails.append(email)
            }
        }
        
        return emails
    }
    
    static func extractDisplayName(from string: String) -> String? {
        if let emailStartIndex = string.firstIndex(of: "<") {
            let name = String(string[..<emailStartIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = sanitizeDisplayName(name)
            return sanitized.isEmpty ? nil : sanitized
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commentStart = trimmed.lastIndex(of: "("),
           trimmed.hasSuffix(")"),
           let emailMatch = firstBareEmailMatch(in: String(trimmed[..<commentStart])),
           !emailMatch.email.isEmpty {
            let comment = trimmed[trimmed.index(after: commentStart)..<trimmed.index(before: trimmed.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = sanitizeDisplayName(comment)
            return sanitized.isEmpty ? nil : sanitized
        }

        if let emailMatch = firstBareEmailMatch(in: trimmed) {
            let leadingName = String(trimmed[..<emailMatch.range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = sanitizeDisplayName(leadingName)
            return sanitized.isEmpty ? nil : sanitized
        }

        return nil
    }

    /// Decodes RFC 2047 encoded-words and strips quoting from a display-name
    /// phrase parsed out of an address header. Decoding happens AFTER the
    /// address structure is parsed so decoded content can never inject a fake
    /// "<addr>" into address parsing, and BEFORE quote-stripping so a name
    /// that only becomes quoted once decoded is still unquoted for display.
    static func sanitizeDisplayName(_ name: String) -> String {
        RFC2047Decoder.decode(name)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts an email username to a formatted display name
    /// e.g., "firstname.lastname" → "Firstname Lastname"
    /// e.g., "john_doe" → "John Doe"
    static func formatAsDisplayName(email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract username part (before @)
        let username: String
        if let atIndex = trimmed.firstIndex(of: "@") {
            username = String(trimmed[..<atIndex])
        } else {
            username = trimmed
        }

        // Split on common separators (dots, underscores, hyphens)
        let parts = username
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }

        // Capitalize each part
        let capitalized = parts.map { part in
            part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }

        return capitalized.joined(separator: " ")
    }

    /// Returns true if newName is "better" than existingName
    /// Better means: more name parts, or same parts but longer
    static func isBetterDisplayName(_ newName: String?, than existingName: String?) -> Bool {
        guard let new = newName, !new.isEmpty else { return false }
        guard let existing = existingName, !existing.isEmpty else { return true }

        let newParts = new.components(separatedBy: " ").filter { !$0.isEmpty }
        let existingParts = existing.components(separatedBy: " ").filter { !$0.isEmpty }

        // More name parts is better (e.g., "John Smith" > "John")
        if newParts.count > existingParts.count { return true }
        if newParts.count < existingParts.count { return false }

        // Same number of parts: longer is better (handles middle names, titles)
        return new.count > existing.count
    }

    /// Returns true if `newName` should replace `existingName` for a specific email.
    /// Address-derived names are weak because they were likely synthesized from the
    /// local part before a real header or contact name was available.
    static func isBetterDisplayName(_ newName: String?, than existingName: String?, forEmail email: String) -> Bool {
        guard let new = newName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !new.isEmpty else { return false }
        guard let existing = existingName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else { return true }

        // A name still carrying a raw RFC 2047 encoded-word is garbage on
        // screen: any decoded candidate beats it, and an undecoded candidate
        // never replaces a clean existing name.
        let existingLooksEncoded = RFC2047Decoder.containsEncodedWord(existing)
        let newLooksEncoded = RFC2047Decoder.containsEncodedWord(new)
        if existingLooksEncoded != newLooksEncoded {
            return existingLooksEncoded
        }

        if isAddressDerivedDisplayName(existing, forEmail: email) {
            if !isAddressDerivedDisplayName(new, forEmail: email) {
                return displayNameParts(new).count >= displayNameParts(existing).count
            }

            if new != existing && hasIntentionalCasing(new) {
                return true
            }
        }

        return isBetterDisplayName(new, than: existing)
    }

    /// Merges one sanitized header From display name into the running winner
    /// for an email, with candidates supplied NEWEST-FIRST.
    ///
    /// The newest header name is authoritative: a sender that deliberately
    /// rebrands ("Technology Brothers" → "TBPN") must not stay pinned to the
    /// old name just because it has more words. An older name may still
    /// replace the newest one when it is a fuller variant of the same name —
    /// the newest name's tokens all appear in it ("Katie" → "Katie Thau") —
    /// and ranks better under `isBetterDisplayName`.
    static func mergeNewestFirstHeaderDisplayName(
        _ olderCandidate: String,
        into newestWinner: String?,
        forEmail email: String
    ) -> String {
        guard let newestWinner else { return olderCandidate }
        guard isDisplayNameTokenSubset(newestWinner, of: olderCandidate),
              isBetterDisplayName(olderCandidate, than: newestWinner, forEmail: email) else {
            return newestWinner
        }
        return olderCandidate
    }

    /// True when every comparison token of `name` appears among `other`'s
    /// tokens — i.e. `other` is a fuller variant of the same name.
    static func isDisplayNameTokenSubset(_ name: String, of other: String) -> Bool {
        let nameParts = displayNameParts(name)
        guard !nameParts.isEmpty else { return false }
        let otherParts = Set(displayNameParts(other))
        return nameParts.allSatisfy { otherParts.contains($0) }
    }

    static func isAddressDerivedDisplayName(_ displayName: String?, forEmail email: String) -> Bool {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else {
            return false
        }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPart: String
        if let atIndex = trimmedEmail.firstIndex(of: "@") {
            localPart = String(trimmedEmail[..<atIndex])
        } else {
            localPart = trimmedEmail
        }

        let comparableDisplayName = displayNameForComparison(displayName)
        return comparableDisplayName == displayNameForComparison(localPart)
            || comparableDisplayName == displayNameForComparison(formatAsDisplayName(email: email))
    }

    /// Returns true for Apple's "Hide My Email" placeholder contact labels.
    ///
    /// These labels represent relay routing aliases rather than real participants
    /// and should be excluded from conversation participant displays.
    static func isHideMyEmailDisplayName(_ displayName: String?) -> Bool {
        guard let displayName else { return false }
        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return normalized == "hide my email"
    }

    private static func firstBareEmailMatch(in string: String) -> (email: String, range: Range<String.Index>)? {
        let atom = #"[A-Z0-9!#$%&'*+/=?^_`{|}~-]+"#
        let localPart = #"\#(atom)(?:\.\#(atom))*"#
        let domainLabel = #"[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?"#
        let domain = #"\#(domainLabel)(?:\.\#(domainLabel))*\.[A-Z]{2,}"#
        let pattern = #"(?:^|[\s<(\[,;])(\#(localPart)@\#(domain))(?=$|[\s>)\],;.!?])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else {
            return nil
        }

        return (String(string[range]), range)
    }

    private static func displayNameForComparison(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func displayNameParts(_ value: String) -> [String] {
        displayNameForComparison(value)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
    }

    private static func hasIntentionalCasing(_ value: String) -> Bool {
        let letters = value.filter { $0.isLetter }
        guard letters.count > 1 else { return false }

        if letters.allSatisfy({ $0.isUppercase }) {
            return true
        }

        return letters.dropFirst().contains { $0.isUppercase }
    }
}
