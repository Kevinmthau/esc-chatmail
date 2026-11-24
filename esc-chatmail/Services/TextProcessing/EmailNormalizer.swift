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

    // Compiled once: these run several times per message on the sync path and
    // twice per `Log.redact(address:)`. Each keeps the options the per-call
    // compile used (none here, `.caseInsensitive` for the bare-address form).
    //
    // Quoted local parts can contain brackets and escaped quotes. Consume
    // them as a unit, but never capture an unquoted nested '<' from a name.
    private static let bracketedEmailRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<((?:"(?:[^"\\]|\\.)*"|[^<>"])+@[^<>]+)>"#)
    }()

    private static let bareEmailRegex: NSRegularExpression? = {
        let atom = #"[A-Z0-9!#$%&'*+/=?^_`{|}~-]+"#
        let localPart = #"\#(atom)(?:\.\#(atom))*"#
        let domainLabel = #"[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?"#
        let domain = #"\#(domainLabel)(?:\.\#(domainLabel))*\.[A-Z]{2,}"#
        let pattern = #"(?:^|[\s<(\[,;])(\#(localPart)@\#(domain))(?=$|[\s>)\],;.!?])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// The address of the first mailbox in an address header value (a whole
    /// From, To or Cc value, or one token of it).
    ///
    /// A display name is the sender's: a quoted name or a comment can hold an
    /// address of its own (`"Boss <boss@corp.example>" <x@attacker.example>`
    /// is one legal mailbox, x@attacker.example, and SPF, DKIM and DMARC align
    /// on it). Taking the first `<…@…>` anywhere in the value read that one as
    /// boss@corp.example, so the message keyed into Boss's chat, showed as
    /// Boss's, and with the user's own address in the quotes was drawn as sent
    /// by the user. So the value is split into mailboxes first
    /// (`EmailAddressListParser.addressTokens`, which knows quoted strings and
    /// comments), and the first mailbox's address is read by
    /// `mailboxAddress(inToken:)`, which skips them.
    static func extractEmail(from string: String) -> String? {
        firstMailbox(in: string)?.match.email
    }

    /// Where a mailbox's address sits in one address token.
    struct MailboxAddressMatch: Equatable {
        /// The address as written (not normalized).
        let email: String
        /// The `<` that opens the angle-addr, or nil for a bare address. The
        /// display name is the text before it.
        let angleStart: String.Index?
    }

    /// The address of the one mailbox in `token` (a value
    /// `EmailAddressListParser.addressTokens` returned), or nil.
    static func mailboxAddress(inToken token: String) -> MailboxAddressMatch? {
        if case .address(let match) = scanMailbox(token) {
            return match
        }
        return nil
    }

    /// What `scanMailbox(_:)` found in one token.
    private enum MailboxScan {
        case address(MailboxAddressMatch)
        /// No address at all, quoted or not.
        case none
        /// Two different addresses outside quoted strings and comments, or an
        /// address in an angle-addr abandoned for a second `<`. Which one is
        /// the mailbox's is the sender's choice, so neither is taken.
        case ambiguous
    }

    /// Reads one token's mailbox, in this order:
    ///
    /// 1. its complete `<…@…>` outside quoted strings and comments: a nested
    ///    `<` restarts the angle-addr, so an unmatched bracket in a name
    ///    (`Tom <3 Jerry <tom@x.com>`) never captures name text. Where two
    ///    different ones are written, or the restart abandons a `<` that held
    ///    an `@`, the token is `.ambiguous`: taking the first or the last
    ///    lets the sender pick, by order, which one the app reads
    ///    (`<x@attacker.example> <me@gmail.com>` was the user's own mail);
    /// 2. else the first bare address outside quoted strings, comments,
    ///    angle-addr comments and domain literals;
    /// 3. else, only where a quote or comment never closes and no `@` is
    ///    outside quotes and comments, the last `<…@…>` anywhere. A token whose quotes and
    ///    comments all close and that has no address outside them has none
    ///    (`"<boss@corp.example>"`, `"John Doe <john@x.com>"`): read as an
    ///    address, a quoted one became a mailbox of its own ahead of the real
    ///    one (`"<boss@corp.example>", <x@attacker.example>`).
    ///
    /// RFC 5322's structure is followed where it decides which text is an
    /// address: quoted strings; comments, which nest, in the phrase and inside
    /// the angle-addr (`<x@attacker.example (><me@gmail.com>)>` is
    /// x@attacker.example, and a comment there is left out of the address);
    /// domain literals (`[…]`), whose `<` and `>` are text; a quoted local
    /// part inside the angle-addr. A backslash escapes the next character only
    /// inside a quoted string, a comment or a domain literal, as RFC 5322's
    /// quoted-pair: read anywhere, `x\"<me@gmail.com>" <x@attacker.example>`
    /// hid the quote that opens the name. `EmailAddressListParser.addressTokens`
    /// follows the same rules, and so does the web app's port
    /// (`web/src/identity/normalizeEmail.ts`), rule for rule. Characters are
    /// read as Unicode scalars, never `Character`s: a quote or an `@`
    /// followed by a combining mark is one `Character` that is neither, and
    /// the web app reads it as the scalar.
    private static func scanMailbox(_ token: String) -> MailboxScan {
        enum Mode { case phrase, quote, comment, angle, angleQuote, angleComment, domainLiteral }
        var mode = Mode.phrase
        var commentDepth = 0
        var previousWasEscape = false
        var angleStart = token.startIndex
        // The angle-addr's text, its comments left out.
        var angleContent = String.UnicodeScalarView()
        var angleHadComment = false
        var abandonedAngleHeldAddress = false
        var completes: [MailboxAddressMatch] = []
        // The token with every quoted string, comment and domain literal
        // blanked, and every complete angle-addr that is not an address, for
        // step 2.
        var phrase: [Unicode.Scalar] = []
        var angleSegmentStart = 0
        // What blanked text becomes: neither an address character nor one
        // the bare-address pattern takes as the end or start of an address.
        // A space ended one, so `me@corp.com(x).attacker.example`, whose
        // domain RFC 5322's obsolete syntax makes corp.com.attacker.example,
        // read as me@corp.com.
        let blank: Unicode.Scalar = "\u{1}"
        // Whether the current angle-addr opened a quoted local part, a
        // comment or a domain literal.
        var angleOpenedStructure = false

        let scalars = token.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let isEscaped = previousWasEscape
            var escapes = false
            switch mode {
            case .phrase:
                if scalar == "\"" {
                    mode = .quote
                    phrase.append(blank)
                } else if scalar == "(" {
                    mode = .comment
                    commentDepth = 1
                    phrase.append(blank)
                } else {
                    if scalar == "<" {
                        mode = .angle
                        angleStart = index
                        angleContent = String.UnicodeScalarView()
                        angleHadComment = false
                        angleOpenedStructure = false
                        angleSegmentStart = phrase.count
                    }
                    phrase.append(scalar)
                }
            case .quote:
                escapes = true
                phrase.append(blank)
                if scalar == "\"" && !isEscaped {
                    mode = .phrase
                }
            case .comment:
                escapes = true
                phrase.append(blank)
                if scalar == "(" && !isEscaped {
                    commentDepth += 1
                } else if scalar == ")" && !isEscaped {
                    commentDepth -= 1
                    if commentDepth == 0 {
                        mode = .phrase
                    }
                }
            case .angle:
                if scalar == "\"" {
                    mode = .angleQuote
                    angleOpenedStructure = true
                    angleContent.append(scalar)
                    phrase.append(blank)
                } else if scalar == "(" {
                    mode = .angleComment
                    commentDepth = 1
                    angleHadComment = true
                    angleOpenedStructure = true
                    phrase.append(blank)
                } else if scalar == "[" {
                    mode = .domainLiteral
                    angleOpenedStructure = true
                    angleContent.append(scalar)
                    phrase.append(blank)
                } else if scalar == "<" {
                    if angleContent.contains("@") {
                        abandonedAngleHeldAddress = true
                    }
                    angleStart = index
                    angleContent = String.UnicodeScalarView()
                    angleHadComment = false
                    angleOpenedStructure = false
                    angleSegmentStart = phrase.count
                    phrase.append(scalar)
                } else if scalar == ">" {
                    phrase.append(scalar)
                    var content = String(angleContent)
                    if angleHadComment {
                        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if isAngleAddressContent(content) {
                        completes.append(MailboxAddressMatch(email: content, angleStart: angleStart))
                    } else {
                        for position in angleSegmentStart..<phrase.count {
                            phrase[position] = blank
                        }
                    }
                    mode = .phrase
                } else {
                    angleContent.append(scalar)
                    phrase.append(scalar)
                }
            case .angleQuote:
                escapes = true
                angleContent.append(scalar)
                phrase.append(blank)
                if scalar == "\"" && !isEscaped {
                    mode = .angle
                }
            case .angleComment:
                escapes = true
                phrase.append(blank)
                if scalar == "(" && !isEscaped {
                    commentDepth += 1
                } else if scalar == ")" && !isEscaped {
                    commentDepth -= 1
                    if commentDepth == 0 {
                        mode = .angle
                    }
                }
            case .domainLiteral:
                escapes = true
                angleContent.append(scalar)
                phrase.append(blank)
                if scalar == "]" && !isEscaped {
                    mode = .angle
                }
            }
            previousWasEscape = escapes && scalar == "\\" && !isEscaped
            index = scalars.index(after: index)
        }

        // An address abandoned for a nested `<` is a second address,
        // whatever follows it.
        if abandonedAngleHeldAddress {
            return .ambiguous
        }
        if let first = completes.first {
            // Compared by scalars, as the web app's `Set` compares them:
            // `String` equality is canonical equivalence, which made an
            // NFC and an NFD spelling one address here and two there.
            let addresses = Set(completes.map { normalize($0.email).unicodeScalars.map(\.value) })
            if addresses.count > 1 {
                return .ambiguous
            }
            return .address(first)
        }
        // An angle-addr that never closed after it opened a quoted local
        // part, a comment or a domain literal is not text for step 2: read
        // there, `<me@gmail.com"> <x@attacker.example>` was the user's own
        // mail. One that opened none (`Name <a@b.com`) still is.
        let endsInsideAngle = mode == .angle || mode == .angleQuote || mode == .angleComment || mode == .domainLiteral
        if endsInsideAngle && angleOpenedStructure {
            for position in angleSegmentStart..<phrase.count {
                phrase[position] = blank
            }
        }
        if let bare = firstBareEmailMatch(in: String(String.UnicodeScalarView(phrase))) {
            return .address(MailboxAddressMatch(email: bare.email, angleStart: nil))
        }
        // Step 3 reads inside an unclosed quote or comment only where nothing
        // outside them has an `@`: a real address the bare-address pattern
        // does not know (`x@attacker.xn--p1ai (<me@gmail.com>`) is still the
        // mailbox's, and reading past it took the quoted one.
        guard mode == .quote || mode == .comment, !phrase.contains("@") else { return .none }
        if let regex = bracketedEmailRegex,
           let match = regex.matches(in: token, range: NSRange(token.startIndex..., in: token)).last,
           let range = Range(match.range(at: 1), in: token),
           let whole = Range(match.range, in: token) {
            return .address(MailboxAddressMatch(email: String(token.unicodeScalars[range]), angleStart: whole.lowerBound))
        }
        return .none
    }

    /// The first mailbox of `string` that holds an address: the text from the
    /// first token through the first token with an address, and that address.
    ///
    /// Tokens before it hold no address at all (not even quoted), so they are
    /// a name with a comma no one quoted: `The River Club of NY, Inc <…>` in a
    /// forwarded message's From line, or an encoded word with a raw comma
    /// (`=?utf-8?Q?Doe,Jane?= <…>`). They stay in the name. Read on their own
    /// they gave a name of `Inc` or `Jane?=`. Joining them adds no address:
    /// each starts in the phrase, where the comma left the scan, and none has
    /// an address for the scan to take; where the joined text still reads
    /// another address than the token alone, the token alone is taken. A
    /// first mailbox that is `.ambiguous` is no address at all, never a reason
    /// to read the next one. `EmailAddressListParser.mailboxes(from:)` reads
    /// each token alone, as the To and Cc parser always has.
    private static func firstMailbox(in string: String) -> (token: String, match: MailboxAddressMatch)? {
        let scalars = string.unicodeScalars
        var nameStart: String.Index?
        for range in EmailAddressListParser.addressTokenRanges(from: string) {
            let token = String(scalars[range])
            switch scanMailbox(token) {
            case .none:
                if nameStart == nil {
                    nameStart = range.lowerBound
                }
            case .ambiguous:
                return nil
            case .address(let match):
                if let nameStart {
                    let mailbox = String(scalars[nameStart..<range.upperBound])
                    if case .address(let joined) = scanMailbox(mailbox),
                       normalize(joined.email) == normalize(match.email) {
                        return (mailbox, joined)
                    }
                }
                return (token, match)
            }
        }
        return nil
    }

    private static let angleAddressContentRegex: NSRegularExpression? = {
        // A quoted-pair is `\\[\s\S]`, not `\\.`: ICU's `.` leaves out
        // U+000B, U+000C and U+0085, which JavaScript's takes, and the web
        // app reads the same content with this pattern.
        try? NSRegularExpression(pattern: #"\A(?:"(?:[^"\\]|\\[\s\S])*"|[^<>"])+@[^<>]+\z"#)
    }()

    /// The bracketed pattern's rule for what may sit between `<` and `>`.
    private static func isAngleAddressContent(_ content: String) -> Bool {
        guard content.unicodeScalars.contains("@"), let regex = angleAddressContentRegex else { return false }
        return regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
    }

    /// The first address anywhere in free text, quoted or not: the leftmost
    /// `<…@…>`, else the first bare address. This is what `extractEmail` was
    /// before it learned quoted names, and it is right only for text that is
    /// not an address header: `isEmailAddressShapedDisplayName` asks it
    /// whether a display name embeds an address, which is the reading that
    /// hides `Boss <boss@corp.example>` and `Acme (support@acme.com)` as
    /// names. Never use it on a header value.
    private static func firstAddressAnywhere(in string: String) -> String? {
        if let regex = bracketedEmailRegex,
           let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
           let range = Range(match.range(at: 1), in: string) {
            return String(string[range])
        }
        return firstBareEmailMatch(in: string)?.email
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
    
    /// The display name of the first mailbox in an address header value: the
    /// text before the `<` that `extractEmail` read the address from, so an
    /// address inside a quoted name stays in the name (where
    /// `isEmailAddressShapedDisplayName` hides it) and never becomes the
    /// mailbox's address.
    static func extractDisplayName(from string: String) -> String? {
        guard let (token, match) = firstMailbox(in: string) else {
            return displayNameWithoutAngleAddress(from: string)
        }
        return displayName(inToken: token, match: match)
    }

    /// The display name of the mailbox `match` read from `token`.
    static func displayName(inToken token: String, match: MailboxAddressMatch) -> String? {
        guard let angleStart = match.angleStart else {
            return displayNameWithoutAngleAddress(from: token)
        }
        // Sliced by scalars, as the scanner read it: a `String` slice rounds
        // an index inside a grapheme down to the grapheme's start.
        let name = String(token.unicodeScalars[..<angleStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = sanitizeDisplayName(name)
        return sanitized.isEmpty ? nil : sanitized
    }

    /// The name of a value whose address is bare (`a@b.com (Name)`,
    /// `Name a@b.com`) or missing, as `extractDisplayName` read every value
    /// before it learned quoted names.
    private static func displayNameWithoutAngleAddress(from string: String) -> String? {
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
    ///
    /// Quote-stripping removes every double quote, then peels the wrapping
    /// quotes `strippingWrappingQuotes(_:)` recognizes. Outlook and Exchange
    /// write a recipient as `'Jacob Laycock' <…>` or `"'Jacob Laycock'" <…>`;
    /// removing only double quotes stored and showed `'Jacob Laycock'`, and
    /// because the quotes hid that it restates jacob.laycock@'s address, it
    /// outranked the plain "Jacob Laycock" in `isBetterDisplayName(_:than:forEmail:)`.
    /// A quote inside a name (`O'Brien`, `'Til Tuesday`) is not wrapping and
    /// stays. The pairs are not matched, so a name that merely starts and ends
    /// with a quoted part (`'Ann' & 'Bob'`) loses its outer two quotes; such
    /// header names are rare enough not to justify parsing quote nesting.
    static func sanitizeDisplayName(_ name: String) -> String {
        strippingWrappingQuotes(
            RFC2047Decoder.decode(name)
                .replacingOccurrences(of: "\"", with: "")
        )
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
    ///
    /// Never true in both directions for one pair, or the stored name would
    /// flip with every header that carries the other one (`EmailNormalizerTests`
    /// checks this over a table of realistic pairs). It can be false in both
    /// directions: such a tie keeps whichever name is already stored.
    static func isBetterDisplayName(_ newName: String?, than existingName: String?, forEmail email: String) -> Bool {
        guard let quotedNew = newName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quotedNew.isEmpty else { return false }
        guard let quotedExisting = existingName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quotedExisting.isEmpty else { return true }

        // Rows stored before `sanitizeDisplayName` peeled Outlook's wrapping
        // quotes still hold `'Jacob Laycock'`. Rank every name as written
        // inside its quotes: the quotes hid that it restates jacob.laycock@'s
        // address, so it replaced the address-derived "Jacob Laycock" at an
        // equal part count and the plain name could never win back, and they
        // made it the longer name in the base ranking. A quoted name and its
        // own unquoted form are one name, and the shorter spelling (fewer
        // quotes) wins, so ingestion heals a quoted row when the name recurs.
        let new = strippingWrappingQuotes(quotedNew)
        let existing = strippingWrappingQuotes(quotedExisting)
        guard !new.isEmpty else { return false }
        guard !existing.isEmpty else { return true }
        if new == existing {
            return quotedNew.count < quotedExisting.count
        }

        // A name still carrying a raw RFC 2047 encoded-word is garbage on
        // screen: any decoded candidate beats it, and an undecoded candidate
        // never replaces a clean existing name.
        let existingLooksEncoded = RFC2047Decoder.containsEncodedWord(existing)
        let newLooksEncoded = RFC2047Decoder.containsEncodedWord(new)
        if existingLooksEncoded != newLooksEncoded {
            return existingLooksEncoded
        }

        // An address used as a display name (a To/Cc header written as
        // `"jacob.laycock@studs.com" <jacob.laycock@studs.com>`) names no one:
        // it never replaces a name, and any name replaces it. Without this the
        // address split into more comparison parts than the address-derived
        // "Jacob Laycock" and won the branch below, while "Jacob Laycock" had
        // more words than the address and won it back, so the stored Person
        // name flipped with header order; an address that replaced a one-word
        // name ("Jake") was longer than any one-word name and never left.
        let existingIsAddress = isEmailAddressShapedDisplayName(existing, forEmail: email)
        let newIsAddress = isEmailAddressShapedDisplayName(new, forEmail: email)
        if existingIsAddress != newIsAddress {
            return existingIsAddress
        }

        // Each branch below decides a pair the same way from both sides. A
        // pair that ranked better in both directions made the stored name
        // follow header order: for jacob.laycock@, the real "Jake Laycock"
        // replaced the address-derived "Jacob Laycock" at an equal part count,
        // and "Jacob Laycock" won it back as the longer name.
        let existingIsDerived = isAddressDerivedDisplayName(existing, forEmail: email)
        let newIsDerived = isAddressDerivedDisplayName(new, forEmail: email)
        if existingIsDerived && !newIsDerived {
            return displayNameParts(new).count >= displayNameParts(existing).count
        }

        if newIsDerived && !existingIsDerived {
            // The converse of the branch above: a derived name replaces a real
            // one only with strictly more parts (a fuller "John Doe" over
            // "John"), never at an equal part count, where the real name wins.
            guard displayNameParts(new).count > displayNameParts(existing).count else { return false }
            return isBetterDisplayName(new, than: existing)
        }

        if newIsDerived && existingIsDerived {
            // Intentional casing ("BONBONWHIMS") beats the auto-formatted
            // "Bonbonwhims" whatever their word counts. Two intentionally cased
            // variants fall through to the base ranking rather than each
            // replacing the other; a case-only pair is a tie that keeps the
            // stored name.
            let newHasIntentionalCasing = hasIntentionalCasing(new)
            if newHasIntentionalCasing != hasIntentionalCasing(existing) {
                return newHasIntentionalCasing
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

    /// A distinct sanitized header From name for one sender, stamped with the
    /// newest message occurrence that carried it, for newest-first ranking.
    struct HeaderDisplayNameCandidate {
        let displayName: String
        let newestInternalDate: Date
        let newestMessageID: String
    }

    /// Picks the winning header display name from a sender's distinct name
    /// candidates by ordering them newest-first (newest occurrence date, then
    /// message id) and folding through `mergeNewestFirstHeaderDisplayName`.
    /// Equivalent to scanning every message newest-first: rows past a name's
    /// first (newest) occurrence only re-merge the same candidate, which
    /// cannot change the winner.
    static func resolveNewestFirstHeaderDisplayName(
        from candidates: [HeaderDisplayNameCandidate],
        forEmail email: String
    ) -> String? {
        let ordered = candidates.sorted {
            if $0.newestInternalDate != $1.newestInternalDate {
                return $0.newestInternalDate > $1.newestInternalDate
            }
            return $0.newestMessageID > $1.newestMessageID
        }

        var winner: String?
        for candidate in ordered {
            winner = mergeNewestFirstHeaderDisplayName(
                candidate.displayName,
                into: winner,
                forEmail: email
            )
        }
        return winner
    }

    /// True when every comparison token of `name` appears among `other`'s
    /// tokens — i.e. `other` is a fuller variant of the same name.
    static func isDisplayNameTokenSubset(_ name: String, of other: String) -> Bool {
        let nameParts = displayNameParts(name)
        guard !nameParts.isEmpty else { return false }
        let otherParts = Set(displayNameParts(other))
        return nameParts.allSatisfy { otherParts.contains($0) }
    }

    /// True when a display name is, or embeds, an email address rather than a
    /// name. `PersonDisplayNameResolver` never shows such a name. Only an
    /// address the bare-address pattern matches counts: a dotted domain ending
    /// in an ASCII label of two or more letters.
    ///
    /// Outlook and Exchange write a recipient that has no name as
    /// `"'jacob.laycock@studs.com'" <jacob.laycock@studs.com>`. Header
    /// sanitizing used to strip only the double quotes, and the bare pattern
    /// rejects the trailing `'`, so that address passed as a name: shown in
    /// titles, and stored as a Person name that no one-word name could
    /// replace. `sanitizeDisplayName` now peels the single quotes too, but
    /// rows stored before it still hold `'addr'`, so wrapping quotes
    /// (`strippingWrappingQuotes(_:)`) are still peeled before matching.
    static func isEmailAddressShapedDisplayName(_ displayName: String) -> Bool {
        embedsBareOrBracketedAddress(strippingWrappingQuotes(displayName))
    }

    /// `isEmailAddressShapedDisplayName(_:)`, or the name, less its wrapping
    /// quotes, is `email` itself. Header extraction takes any address inside
    /// angle brackets, so a header that repeats a dotless, internationalized
    /// or domain-literal address (`"ops@intranet" <ops@intranet>`) yields a
    /// name the bare pattern does not match; comparing with the participant's
    /// own address still catches it. `isBetterDisplayName(_:than:forEmail:)`
    /// never lets such a name replace a name.
    static func isEmailAddressShapedDisplayName(_ displayName: String, forEmail email: String) -> Bool {
        let candidate = strippingWrappingQuotes(displayName)
        return embedsBareOrBracketedAddress(candidate)
            || (candidate.contains("@") && normalize(candidate) == normalize(email))
    }

    /// The match both `isEmailAddressShapedDisplayName` overloads share, on a
    /// value whose wrapping quotes are already peeled.
    private static func embedsBareOrBracketedAddress(_ candidate: String) -> Bool {
        candidate.contains("@") && firstAddressAnywhere(in: candidate) != nil
    }

    private static let wrappingQuotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""),
        ("'", "'"),
        ("\u{201C}", "\u{201D}"),
        ("\u{2018}", "\u{2019}"),
        ("\u{00AB}", "\u{00BB}")
    ]

    /// The opening quote of every pair `strippingWrappingQuotes(_:)` peels,
    /// for a store query that narrows a scan to rows that may be wrapped.
    static let wrappingQuoteOpeners: [String] = wrappingQuotePairs.map { String($0.open) }

    /// `value`, trimmed, with every layer of wrapping quotes ("…", '…', “…”,
    /// ‘…’, «…») peeled off, as Outlook writes an address it repeats as the
    /// name (`'ops@intranet'`) or quotes a name; anything else is only
    /// trimmed. Shared with `sanitizeDisplayName`, the ranking in
    /// `isBetterDisplayName(_:than:forEmail:)`, `PersonDisplayNameResolver`,
    /// `NewContactPrefillPolicy` and the stored-row repair
    /// (`DataCleanupService.peelQuoteWrappedDisplayNamesIfNeeded`), so they
    /// all agree on what counts as quoting.
    static func strippingWrappingQuotes(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var didStrip = true
        while didStrip, result.count >= 2 {
            didStrip = false
            for pair in wrappingQuotePairs where result.first == pair.open && result.last == pair.close {
                result = String(result.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
                break
            }
        }
        return result
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
        var normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        normalized = collapsingWhitespaceRuns(normalized)

        return normalized == "hide my email"
    }

    private static func firstBareEmailMatch(in string: String) -> (email: String, range: Range<String.Index>)? {
        guard let regex = bareEmailRegex,
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else {
            return nil
        }

        return (String(string[range]), range)
    }

    private static func displayNameForComparison(_ value: String) -> String {
        collapsingWhitespaceRuns(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        )
        .lowercased()
    }

    /// `\s+` → " " through the shared compiled regex; the same ICU `\s` class
    /// the per-call `replacingOccurrences(of:options: .regularExpression)` used.
    private static func collapsingWhitespaceRuns(_ value: String) -> String {
        RegexSanitizer.replace(in: value, regex: RegexSanitizer.whitespaceRunRegex, with: " ")
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
