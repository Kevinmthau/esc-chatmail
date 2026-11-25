import Foundation

/// The one walk of a Gmail message's MIME tree that decides its body: which
/// text/html and text/plain leaves hold the message's words. Sync
/// (`MessageProcessor.extractContent`) and recovery
/// (`HTMLContentRecoveryService`) both read a body through it, so the HTML
/// recovered after a body file was lost is the HTML sync stored
/// (architecture review gap-message-shape-extremes#3 and
/// gap-mime-decoding-i18n#4). `web/src/mime/mimeBody.ts` ports it rule for
/// rule.
///
/// It does no I/O of its own. `decodedBody` is the caller's, and so is the
/// failure policy: sync's throws on a transient fetch failure, a continuation
/// segment's included (the body-materialization contract: a part that could
/// not be fetched must not leave a shorter body behind an advancing cursor),
/// and answers nil only for a 404 or an undecodable response; recovery's
/// answers nil for every failure.
///
/// The walk keeps, for each kind, the first leaf in tree order that is not
/// blank, as it always has: the choice within a multipart/alternative, the
/// root of a multipart/related, and two text parts side by side in a
/// multipart/mixed (a list's footer after the body) are what they were. The
/// one addition is the body a mail client splits around something it placed
/// in the text. iPhone Mail sends a photo placed mid-message as
/// multipart/mixed [text, photo, text], and Apple Mail an inline PDF the same
/// way inside the HTML alternative; the first-wins walk kept only the words
/// before the photo. So inside a multipart/mixed a text leaf directly after a
/// part with an `inline` disposition that is a file (`isInlineFilePart`) is
/// joined to the leaf of its kind the same multipart/mixed gave the body:
/// plain text after a blank line, HTML as the content of its `<body>` put
/// before the first fragment's `</body>` (`joinedHTML`). A fragment that is
/// blank, or HTML with nothing visible, is left out, and nothing stands in
/// for the photo: the stored HTML is what the preview and the rich-content
/// verdict read, and a placeholder would turn ordinary photo mail into a card.
/// A file with an `attachment` disposition does not join what follows it: a
/// list server's footer after an attached file is not the sender's words.
/// The join is bounded (`maximumContinuationsPerKind`,
/// `maximumContinuationUTF8Bytes`), and a continuation past either bound is
/// not fetched at all. The count bound counts every continuation read, joined
/// or not: a blank or invisible fragment is refused only after it was
/// fetched, and a sender could otherwise have any number of them fetched.
enum MIMEBodyExtractor {
    /// The two kinds of body the walk can be asked for.
    enum Kind: Sendable, Hashable {
        case html
        case plainText
    }

    /// The body a walk found: the first leaf of each kind, with its
    /// continuations joined. A kind the walk was not asked for stays nil.
    struct Body: Sendable, Equatable {
        var html: String?
        var plainText: String?

        subscript(kind: Kind) -> String? {
            get {
                switch kind {
                case .html: return html
                case .plainText: return plainText
                }
            }
            set {
                switch kind {
                case .html: html = newValue
                case .plainText: plainText = newValue
                }
            }
        }
    }

    /// Continuations read for a body of one kind, at most, in one message,
    /// whether or not each was joined.
    static let maximumContinuationsPerKind = 15

    /// Bytes of continuation read for a body of one kind, at most, in one
    /// message, whether or not each was joined: a refused fragment has still
    /// been fetched and checked for visible content (on web by regular
    /// expressions that are quadratic in it). A continuation whose declared
    /// size or decoded text would pass it is left out, unfetched where its
    /// size is declared.
    static let maximumContinuationUTF8Bytes = 2 * 1024 * 1024

    private struct ContinuationBudget {
        var readCount: [Kind: Int] = [:]
        var readBytes: [Kind: Int] = [:]

        func remainingBytes(for kind: Kind) -> Int {
            MIMEBodyExtractor.maximumContinuationUTF8Bytes - readBytes[kind, default: 0]
        }

        func admitsAnother(_ kind: Kind) -> Bool {
            readCount[kind, default: 0] < MIMEBodyExtractor.maximumContinuationsPerKind &&
                remainingBytes(for: kind) > 0
        }
    }

    /// Walks `part` for the kinds asked for. `decodedBody` is called once for
    /// each leaf the body may take, in tree order, and never for a file.
    static func extract(
        from part: MessagePart,
        kinds: Set<Kind> = [.html, .plainText],
        decodedBody: (MessagePart) async throws -> String?
    ) async throws -> Body {
        var budget = ContinuationBudget()
        return try await walk(part, kinds: kinds, budget: &budget, decodedBody: decodedBody)
    }

    private static func walk(
        _ part: MessagePart,
        kinds: Set<Kind>,
        budget: inout ContinuationBudget,
        decodedBody: (MessagePart) async throws -> String?
    ) async throws -> Body {
        if isAttachmentContentPart(part) {
            return Body()
        }

        let mimeType = resolvedMimeType(for: part)
        if let kind = kind(ofLeafMimeType: mimeType) {
            var body = Body()
            if kinds.contains(kind) {
                body[kind] = nonBlank(try await decodedBody(part))
            }
            return body
        }

        guard let parts = part.parts, !parts.isEmpty else {
            return Body()
        }

        let joinsContinuations = isMultipartMixed(mimeType)
        var body = Body()
        var kindsFromOwnLeaves: Set<Kind> = []
        var followsInlineFile = false

        for child in parts {
            defer { followsInlineFile = isInlineFilePart(child) }

            if joinsContinuations,
               followsInlineFile,
               let kind = bodyLeafKind(of: child),
               kinds.contains(kind),
               kindsFromOwnLeaves.contains(kind),
               let base = body[kind] {
                body[kind] = try await joiningContinuation(
                    child,
                    of: kind,
                    to: base,
                    budget: &budget,
                    decodedBody: decodedBody
                )
                continue
            }

            // Once every kind asked for has a body, only a continuation can
            // still change it, and nothing else is walked or fetched. A child
            // is asked only for the kinds still missing: what it found of
            // another kind would be dropped, and joining it would spend that
            // kind's bound on fetches whose result is dropped, so sync (both
            // kinds) could refuse a continuation that recovery (HTML only)
            // joins.
            let missingKinds = kinds.filter { body[$0] == nil }
            guard !missingKinds.isEmpty else {
                continue
            }

            let childBody = try await walk(child, kinds: missingKinds, budget: &budget, decodedBody: decodedBody)
            let childLeafKind = bodyLeafKind(of: child)
            for kind in missingKinds {
                guard let value = childBody[kind] else { continue }
                body[kind] = value
                if childLeafKind == kind {
                    kindsFromOwnLeaves.insert(kind)
                }
            }
        }

        return body
    }

    private static func joiningContinuation(
        _ part: MessagePart,
        of kind: Kind,
        to base: String,
        budget: inout ContinuationBudget,
        decodedBody: (MessagePart) async throws -> String?
    ) async throws -> String {
        guard budget.admitsAnother(kind) else { return base }
        let remaining = budget.remainingBytes(for: kind)
        if let declaredSize = part.body?.size, declaredSize > remaining {
            return base
        }

        budget.readCount[kind, default: 0] += 1
        guard let fragment = nonBlank(try await decodedBody(part)) else {
            return base
        }
        let fragmentBytes = fragment.utf8.count
        guard fragmentBytes <= remaining else { return base }
        budget.readBytes[kind, default: 0] += fragmentBytes

        let joined: String
        switch kind {
        case .plainText:
            joined = joinedPlainText(base, appending: fragment)
        case .html:
            guard HTMLMeaningfulContentChecker.hasMeaningfulContent(fragment) else {
                return base
            }
            joined = joinedHTML(base, appending: fragment)
        }
        return joined
    }

    // MARK: - Joining

    /// `base`, then a blank line, then `fragment`, with the line breaks at the
    /// seam made exactly one blank line. The breaks are taken off by a scan
    /// from each end, never a regular expression: `[\r\n]+\z` backtracks
    /// through every run of line breaks the sender's text holds, and 40,000
    /// of them took 15 s in ICU.
    static func joinedPlainText(_ base: String, appending fragment: String) -> String {
        var head = base.unicodeScalars[...]
        while let last = head.last, last == "\r" || last == "\n" {
            head.removeLast()
        }
        var tail = fragment.unicodeScalars[...]
        while let first = tail.first, first == "\r" || first == "\n" {
            tail.removeFirst()
        }
        return String(head) + "\n\n" + String(tail)
    }

    /// `base` with the content of `fragment`'s `<body>` put before `base`'s
    /// last `</body` (else its last `</html`, else its end). A fragment with
    /// no `<body>` tag is put whole. Tag names are matched in ASCII case only
    /// and the text is cut only at ASCII characters, so the result is the
    /// same as web's, which works on UTF-16 code units.
    static func joinedHTML(_ base: String, appending fragment: String) -> String {
        let fragmentBytes = Array(fragment.utf8)
        let content: ArraySlice<UInt8>
        if let bodyStart = endOfOpeningBodyTag(in: fragmentBytes) {
            let end = lastOffset(of: closingBodyTag, in: fragmentBytes, from: bodyStart)
                ?? lastOffset(of: closingHTMLTag, in: fragmentBytes, from: bodyStart)
                ?? fragmentBytes.count
            content = fragmentBytes[bodyStart..<end]
        } else {
            content = fragmentBytes[...]
        }

        let baseBytes = Array(base.utf8)
        let insertion = lastOffset(of: closingBodyTag, in: baseBytes, from: 0)
            ?? lastOffset(of: closingHTMLTag, in: baseBytes, from: 0)
            ?? baseBytes.count

        var joined = [UInt8]()
        joined.reserveCapacity(baseBytes.count + content.count)
        joined.append(contentsOf: baseBytes[..<insertion])
        joined.append(contentsOf: content)
        joined.append(contentsOf: baseBytes[insertion...])
        return String(decoding: joined, as: UTF8.self)
    }

    private static let openingBodyTag = Array("<body".utf8)
    private static let closingBodyTag = Array("</body".utf8)
    private static let closingHTMLTag = Array("</html".utf8)

    /// The offset just past the `>` of the first `<body` start tag, or nil
    /// when there is none or it never ends. A `>` inside a quoted attribute
    /// value (a quote right after `=`) does not end the tag.
    private static func endOfOpeningBodyTag(in bytes: [UInt8]) -> Int? {
        var start = 0
        while let tagStart = firstOffset(of: openingBodyTag, in: bytes, from: start) {
            let afterName = tagStart + openingBodyTag.count
            guard afterName < bytes.count else { return nil }
            let next = bytes[afterName]
            guard isHTMLWhitespace(next) || next == UInt8(ascii: "/") || next == UInt8(ascii: ">") else {
                start = tagStart + 1
                continue
            }

            var index = afterName
            var quote: UInt8?
            var followsEquals = false
            while index < bytes.count {
                let byte = bytes[index]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == UInt8(ascii: ">") {
                    return index + 1
                } else if byte == UInt8(ascii: "=") {
                    followsEquals = true
                } else if (byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'")) && followsEquals {
                    quote = byte
                    followsEquals = false
                } else if !isHTMLWhitespace(byte) {
                    followsEquals = false
                }
                index += 1
            }
            return nil
        }
        return nil
    }

    private static func isHTMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private static func firstOffset(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard pattern.count <= bytes.count else { return nil }
        var index = start
        while index <= bytes.count - pattern.count {
            if matchesASCIICaseInsensitive(pattern, in: bytes, at: index) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func lastOffset(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard pattern.count <= bytes.count else { return nil }
        var index = bytes.count - pattern.count
        while index >= start {
            if matchesASCIICaseInsensitive(pattern, in: bytes, at: index) {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// `pattern` is lowercase ASCII.
    private static func matchesASCIICaseInsensitive(_ pattern: [UInt8], in bytes: [UInt8], at offset: Int) -> Bool {
        for (index, expected) in pattern.enumerated() {
            var byte = bytes[offset + index]
            if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") {
                byte += 0x20
            }
            if byte != expected { return false }
        }
        return true
    }

    // MARK: - Classifying parts

    /// The part's MIME type, else its Content-Type header's value.
    static func resolvedMimeType(for part: MessagePart) -> String? {
        if let directMimeType = part.mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !directMimeType.isEmpty {
            return directMimeType
        }

        guard let contentType = part.headers?
            .first(where: { $0.name.lowercased() == "content-type" })?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !contentType.isEmpty else {
            return nil
        }

        return contentType
    }

    static func isHTMLMimeType(_ mimeType: String?) -> Bool {
        normalizedMimeType(mimeType)?.hasPrefix("text/html") == true
    }

    static func isPlainTextMimeType(_ mimeType: String?) -> Bool {
        normalizedMimeType(mimeType)?.hasPrefix("text/plain") == true
    }

    private static func isMultipartMixed(_ mimeType: String?) -> Bool {
        normalizedMimeType(mimeType)?.hasPrefix("multipart/mixed") == true
    }

    private static func normalizedMimeType(_ mimeType: String?) -> String? {
        guard let mimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mimeType.isEmpty else {
            return nil
        }
        return mimeType
    }

    private static func kind(ofLeafMimeType mimeType: String?) -> Kind? {
        if isHTMLMimeType(mimeType) { return .html }
        if isPlainTextMimeType(mimeType) { return .plainText }
        return nil
    }

    /// A file by MIME semantics: a filename, or an `attachment` disposition.
    /// Such a part is never a body, whatever its type.
    static func isAttachmentContentPart(_ part: MessagePart) -> Bool {
        let trimmedFilename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFilename.isEmpty {
            return true
        }

        return contentDisposition(of: part).contains("attachment")
    }

    /// The kind of body `part` is, when it is a text leaf the walk reads
    /// (text/html or text/plain, not a file, not a container); else nil.
    static func bodyLeafKind(of part: MessagePart) -> Kind? {
        guard part.parts?.isEmpty ?? true, !isAttachmentContentPart(part) else {
            return nil
        }
        return kind(ofLeafMimeType: resolvedMimeType(for: part))
    }

    /// Something a mail client placed in the text: a leaf whose disposition
    /// type is `inline` and that is not itself a body leaf (it has a filename,
    /// or a type other than text/html and text/plain).
    static func isInlineFilePart(_ part: MessagePart) -> Bool {
        guard part.parts?.isEmpty ?? true,
              !normalizedMimeTypeIsMultipart(resolvedMimeType(for: part)),
              bodyLeafKind(of: part) == nil else {
            return false
        }
        let dispositionType = contentDisposition(of: part)
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return dispositionType == "inline"
    }

    private static func normalizedMimeTypeIsMultipart(_ mimeType: String?) -> Bool {
        normalizedMimeType(mimeType)?.hasPrefix("multipart/") == true
    }

    private static func contentDisposition(of part: MessagePart) -> String {
        part.headers?
            .first(where: { $0.name.lowercased() == "content-disposition" })?
            .value
            .lowercased() ?? ""
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
