import Foundation

enum MessageBubbleHTMLAnalysisBuilder {
    static func build(
        canonicalHTML: String?,
        parsedEmail: ParsedEmail? = nil,
        hasHTMLSourceHint: Bool,
        isForwardedEmail: Bool,
        isFromMe: Bool = false,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String? = nil,
        senderEmail: String? = nil,
        subject: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot]
    ) -> MessageBubbleHTMLAnalysis {
        build(
            canonicalHTML: canonicalHTML,
            parsedEmail: parsedEmail,
            hasHTMLSource: hasHTMLSourceHint || canonicalHTML != nil,
            isForwardedEmail: isForwardedEmail,
            isFromMe: isFromMe,
            isLikelyCalendarInvite: isLikelyCalendarInvite,
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            attachmentSnapshots: attachmentSnapshots
        )
    }

    static func build(
        messageID: String,
        bodyStorageURI: String?,
        hasHTMLSourceHint: Bool,
        isForwardedEmail: Bool,
        isFromMe: Bool = false,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String? = nil,
        senderEmail: String? = nil,
        subject: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot],
        handler: HTMLContentHandler
    ) -> MessageBubbleHTMLAnalysis {
        let canonicalHTML = loadHTML(
            messageID: messageID,
            bodyStorageURI: bodyStorageURI,
            handler: handler
        )
        let hasHTMLSource = hasHTMLSourceHint || canonicalHTML != nil

        return build(
            canonicalHTML: canonicalHTML,
            parsedEmail: nil,
            hasHTMLSource: hasHTMLSource,
            isForwardedEmail: isForwardedEmail,
            isFromMe: isFromMe,
            isLikelyCalendarInvite: isLikelyCalendarInvite,
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            attachmentSnapshots: attachmentSnapshots
        )
    }

    private static func loadHTML(
        messageID: String,
        bodyStorageURI: String?,
        handler: HTMLContentHandler
    ) -> String? {
        if let html = handler.loadHTML(for: messageID) {
            return html
        }

        guard let bodyStorageURI else {
            return nil
        }

        if handler.migrateIfNeeded(from: bodyStorageURI),
           let migratedHTML = handler.loadHTML(for: messageID) {
            return migratedHTML
        }

        guard let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return handler.loadHTML(from: resolvedURL)
    }

    private static func extractNonDisplayableInlineContentIDs(
        from html: String?,
        parsedEmail: ParsedEmail?,
        attachments: [MessageBubbleAttachmentSnapshot],
        usesExpandedHeuristics: Bool,
        signatureBoundaries: SignatureBoundaryOffsets?
    ) -> Set<String> {
        guard let html else { return [] }

        let originalReferenced = extractReferencedContentIDs(from: html, parsedEmail: parsedEmail)
        guard !originalReferenced.isEmpty else { return [] }

        let cleaned = cleanedHTMLForAttachmentFiltering(from: html)
        let cleanedReferenced = extractReferencedContentIDs(from: cleaned)
        let removedByHTMLCleanup = originalReferenced.subtracting(cleanedReferenced)

        // Structural containment: an inline image referenced only from inside a
        // quoted-history or signature container is a quoted/signature asset
        // regardless of its dimensions or filename — the reliable altitude for
        // the decision. The dimension/keyword heuristics below remain only as a
        // fallback for container-less "loose sibling" signatures (a bare sign-off
        // line followed by an image) that have no subtree to anchor to. Unlike
        // `removedByHTMLCleanup`, containment does not depend on whether stripping
        // the quote/signature leaves meaningful content, so it still fires on a
        // message that is entirely a quoted reply. The "only inside" form keeps
        // an image that the live body also references (which the quoted history
        // re-references) displayable.
        let insideQuotedOrSignatureContainer = inlineContentIDsReferencedOnlyInsideContainers(
            from: html
        )

        let likelySignatureInline = extractLikelySignatureInlineContentIDs(
            boundaries: signatureBoundaries,
            attachments: attachments,
            usesExpandedHeuristics: usesExpandedHeuristics
        )

        return removedByHTMLCleanup
            .union(insideQuotedOrSignatureContainer)
            .union(likelySignatureInline)
    }

    private static func inlineContentIDsReferencedOnlyInsideContainers(
        from html: String
    ) -> Set<String> {
        guard let document = EmailDocument.tryParse(html) else { return [] }
        return document.inlineContentIDsReferencedOnlyInside(
            subtreesMatching: quotedOrSignatureContainerSelectors
        )
    }

    private static func cleanedHTMLForAttachmentFiltering(from html: String) -> String {
        HTMLCleanupFallback.cleanedHTML(from: html, modes: [.quotedAndSignatures, .quotedOnly]).html
    }

    private static func extractReferencedContentIDs(
        from html: String?,
        parsedEmail: ParsedEmail? = nil
    ) -> Set<String> {
        guard let html else { return [] }

        if parsedEmail?.canonicalHTML == html {
            return parsedEmail?.referencedInlineContentIDs ?? []
        }

        if let document = EmailDocument.tryParse(html) {
            return document.referencedInlineContentIDs()
        }
        return EmailDocument.referencedContentIDs(in: html)
    }

    private static func extractLikelySignatureInlineContentIDs(
        boundaries: SignatureBoundaryOffsets?,
        attachments: [MessageBubbleAttachmentSnapshot],
        usesExpandedHeuristics: Bool
    ) -> Set<String> {
        // nil means the lowercased HTML holds no "cid:" reference, the case
        // this function's own guard used to return [] for.
        guard let boundaries else {
            return []
        }

        let lowercasedHTML = boundaries.lowercasedHTML
        let hardSignatureBoundaryOffset = boundaries.hardSignatureBoundaryOffset
        let replyBoundaryOffset = boundaries.replyBoundaryOffset
        let trailingSignatureStartOffsets = boundaries.trailingSignatureStartOffsets
        // Branding-only evidence still needs an asset-like identity. A sign-off
        // corroborated by contact/role text is strong enough to judge dimensions
        // without guessing which mail client's filename produced the image.
        let corroboratedOffsets = boundaries.corroboratedSignOffOffsets

        let firstSignOffOffset = standaloneSignOffRanges(in: lowercasedHTML).first.map {
            lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: $0.lowerBound)
        }
        var nonDisplayable = Set<String>()
        var bodyReferenced = Set<String>()
        EmailDocument.scanReferencedContentIDs(in: lowercasedHTML) { normalizedCID, valueStart in
            let cidOffset = lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: valueStart)
            let isAfterHardBoundary = hardSignatureBoundaryOffset.map { cidOffset >= $0 } ?? false
            let isAfterReplyBoundary = replyBoundaryOffset.map { cidOffset >= $0 } ?? false
            let isAfterCorroboratedSignOff = corroboratedOffsets.contains { cidOffset >= $0 }
            let isAfterBrandingSignOff = trailingSignatureStartOffsets.contains { cidOffset >= $0 }

            // Inspect this occurrence, not the document's first CID. A logo
            // mockup followed by body instructions remains real message content.
            let occurrenceStart = isInsideHTMLTag(in: lowercasedHTML, at: valueStart)
                ? lowercasedHTML[..<valueStart].lastIndex(of: "<") ?? valueStart
                : lowercasedHTML.index(valueStart, offsetBy: -4)
            let occurrenceEnd = replyBoundaryOffset.flatMap { offset in
                offset > cidOffset ? lowercasedHTML.index(lowercasedHTML.startIndex, offsetBy: offset) : nil
            } ?? lowercasedHTML.endIndex
            let occurrenceHTML = String(lowercasedHTML[occurrenceStart..<occurrenceEnd])
            let followingHTML = htmlAfterFirstCIDBeforeNextSignOff(in: occurrenceHTML) ?? ""
            let hasFollowingBodyProse = signatureContactOrRoleLines(in: followingHTML).contains(where: isBodyProseLine)
            let isBeforeCorroboratedSignOff = !isAfterCorroboratedSignOff &&
                !isAfterBrandingSignOff && corroboratedOffsets.contains { cidOffset < $0 }
            let isBeforeSignOff = (firstSignOffOffset.map { cidOffset < $0 } ?? false) ||
                isBeforeCorroboratedSignOff
            if usesExpandedHeuristics && (hasFollowingBodyProse || isBeforeSignOff) &&
                !isAfterReplyBoundary && !isAfterHardBoundary {
                bodyReferenced.insert(normalizedCID)
                return
            }

            // Body prose can resume after a loose signature and before an image.
            // That image remains authored content regardless of its asset name.
            let usesLooseSignatureHeuristics = usesExpandedHeuristics &&
                !isAfterHardBoundary && !isAfterReplyBoundary
            if usesLooseSignatureHeuristics,
               let signOffOffset = trailingSignatureStartOffsets.last(where: { $0 < cidOffset }) {
                let signOffStart = lowercasedHTML.index(lowercasedHTML.startIndex, offsetBy: signOffOffset)
                let precedingHTML = String(lowercasedHTML[signOffStart..<occurrenceStart])
                if signatureContactOrRoleLines(in: precedingHTML).contains(where: isBodyProseLine) {
                    bodyReferenced.insert(normalizedCID)
                    return
                }
            }

            // Container membership is handled structurally above. Preserve the
            // old identity gates after offset-only hard/reply markers, which can
            // precede body siblings outside those containers.
            guard isLikelySignatureInlineAttachment(
                contentID: normalizedCID,
                attachments: attachments,
                htmlImageDimensions: imageDimensions(in: lowercasedHTML, at: valueStart),
                hasCorroboratedRegion: isAfterHardBoundary || isAfterReplyBoundary || isAfterCorroboratedSignOff,
                hasBrandingRegion: isAfterBrandingSignOff,
                allowsDimensionOnlyClassification: isAfterCorroboratedSignOff,
                usesExpandedHeuristics: usesLooseSignatureHeuristics
            ) else {
                bodyReferenced.insert(normalizedCID)
                return
            }

            nonDisplayable.insert(normalizedCID)
        }
        nonDisplayable.subtract(bodyReferenced)

        return nonDisplayable
    }

    private static func hasFollowingBodyProse(in html: String, at valueStart: String.Index, before replyOffset: Int?) -> Bool {
        let cidOffset = html.distance(from: html.startIndex, to: valueStart)
        let start = isInsideHTMLTag(in: html, at: valueStart)
            ? html[..<valueStart].lastIndex(of: "<") ?? valueStart
            : html.index(valueStart, offsetBy: -4)
        let end = replyOffset.flatMap { offset in
            offset > cidOffset ? html.index(html.startIndex, offsetBy: offset) : nil
        } ?? html.endIndex
        let followingHTML = htmlAfterFirstCIDBeforeNextSignOff(in: String(html[start..<end])) ?? ""
        return signatureContactOrRoleLines(in: followingHTML).contains(where: isBodyProseLine)
    }

    private static func firstHardSignatureBoundaryOffset(in lowercasedHTML: String) -> Int? {
        let trustedOffsets = trustedSignatureWrapperMarkers.compactMap { marker -> Int? in
            guard let range = lowercasedHTML.range(of: marker) else { return nil }
            return lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: range.lowerBound)
        }

        let authoredOffsets = authoredSignatureWrapperRegexes.compactMap { regex in
            firstCorroboratedAuthoredSignatureMarkerOffset(matching: regex, in: lowercasedHTML)
        }

        return (trustedOffsets + authoredOffsets).min()
    }

    // Exact `signature` class/id tokens are author-authored and ambiguous (e.g.
    // a "Signature Collection" marketing block near the top of a newsletter).
    // Only treat such a marker as a hard boundary when a real
    // signature signal — branding, a contact, or a role line — follows it within
    // the trailing window, so a stray class name does not suppress every later
    // inline image.
    private static func firstCorroboratedAuthoredSignatureMarkerOffset(
        matching regex: NSRegularExpression,
        in lowercasedHTML: String
    ) -> Int? {
        var searchStart = lowercasedHTML.startIndex
        while let range = firstMatchRange(
            of: regex,
            in: lowercasedHTML,
            range: searchStart..<lowercasedHTML.endIndex
        ) {
            let windowEnd = lowercasedHTML.index(
                range.upperBound,
                offsetBy: signatureSignalTrailingHTMLLimit,
                limitedBy: lowercasedHTML.endIndex
            ) ?? lowercasedHTML.endIndex
            let trailingHTML = String(lowercasedHTML[range.upperBound..<windowEnd])
            if authoredSignatureWrapperHasSignal(in: trailingHTML) {
                return lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: range.lowerBound)
            }

            searchStart = range.upperBound
        }

        return nil
    }

    private static func authoredSignatureWrapperHasSignal(in trailingHTML: String) -> Bool {
        if signatureBrandingMarkers.contains(where: { trailingHTML.contains($0) }) {
            return true
        }

        return hasSignatureContactOrRoleLine(in: signatureContactOrRoleLines(in: trailingHTML))
    }

    private static func firstReplyBoundaryOffset(in lowercasedHTML: String) -> Int? {
        var candidates: [Int] = []
        for regex in replyOnAttributionBoundaryRegexes {
            for replyAttributionRange in regexRanges(of: regex, in: lowercasedHTML)
                where replyOnAttributionHasDateOrEmailSignal(in: lowercasedHTML[replyAttributionRange]) {
                candidates.append(
                    lowercasedHTML.distance(
                        from: lowercasedHTML.startIndex,
                        to: replyAttributionRange.lowerBound
                    )
                )
            }
        }

        for regex in standaloneReplyAttributionBoundaryRegexes {
            for replyAttributionRange in regexRanges(of: regex, in: lowercasedHTML) {
                candidates.append(
                    lowercasedHTML.distance(
                        from: lowercasedHTML.startIndex,
                        to: replyAttributionRange.lowerBound
                    )
                )
            }
        }

        for regex in replyHeaderBoundaryRegexes {
            if let replyHeaderRange = firstMatchRange(of: regex, in: lowercasedHTML) {
                let replyHeaderOffset = lowercasedHTML.distance(
                    from: lowercasedHTML.startIndex,
                    to: replyHeaderRange.lowerBound
                )
                candidates.append(replyHeaderOffset)
            }
        }

        return candidates.min()
    }

    private static func replyOnAttributionHasDateOrEmailSignal(in attributionHTML: Substring) -> Bool {
        matches(replyAttributionDateOrEmailSignalRegex, String(attributionHTML))
    }

    private static func signatureSignalSearchRange(
        in lowercasedHTML: String,
        before offset: Int?
    ) -> Range<String.Index> {
        let endIndex: String.Index
        if let offset {
            endIndex = lowercasedHTML.index(lowercasedHTML.startIndex, offsetBy: offset)
        } else {
            endIndex = lowercasedHTML.endIndex
        }

        let availableLength = lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: endIndex)
        let startIndex = lowercasedHTML.index(
            endIndex,
            offsetBy: -min(availableLength, 8_000)
        )
        return startIndex..<endIndex
    }

    /// Both offset sets `extractLikelySignatureInlineContentIDs` keys off, from
    /// one pass: the contact/role ranges feed `corroboratedSignOffOffsets` as
    /// well as the sorted union, so that filter runs once instead of twice
    /// over the same search range.
    private static func standaloneTrailingSignatureStartOffsets(
        in lowercasedHTML: String,
        before offset: Int?
    ) -> (trailingSignatureStartOffsets: [Int], corroboratedSignOffOffsets: [Int]) {
        let searchRange = signatureSignalSearchRange(in: lowercasedHTML, before: offset)
        let brandingRanges = standaloneSignOffBrandingRanges(in: lowercasedHTML, range: searchRange)
        let contactOrRoleRanges = standaloneSignOffContactOrRoleRanges(in: lowercasedHTML, range: searchRange)
        func startOffset(of range: Range<String.Index>) -> Int {
            lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: range.lowerBound)
        }
        let offsets = (brandingRanges + contactOrRoleRanges).map(startOffset(of:))
        return (
            trailingSignatureStartOffsets: Array(Set(offsets)).sorted(),
            corroboratedSignOffOffsets: contactOrRoleRanges.map(startOffset(of:))
        )
    }

    private static func standaloneSignOffBrandingRanges(
        in lowercasedHTML: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        regexRanges(
            of: standaloneSignOffBeforeBrandingRegex,
            in: lowercasedHTML,
            range: range
        ).filter { range in
            let matchedHTML = lowercasedHTML[range.lowerBound..<range.upperBound]
            return brandingSignalBelongsToSignature(in: matchedHTML)
        }
    }

    private static func standaloneSignOffContactOrRoleRanges(
        in lowercasedHTML: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let searchRange = range ?? lowercasedHTML.startIndex..<lowercasedHTML.endIndex
        return standaloneSignOffRanges(in: lowercasedHTML, range: searchRange).filter { signOffRange in
            let trailingRange = signOffRange.upperBound..<searchRange.upperBound
            let trailingHTML = String(lowercasedHTML[trailingRange].prefix(signatureSignalTrailingHTMLLimit))
            let signalHTML = htmlBeforeFirstCID(in: trailingHTML)
            if hasSignatureContactOrRoleLine(in: signatureContactOrRoleLines(in: signalHTML)) {
                return true
            }

            guard (
                signatureIntroAllowsPostCIDContact(in: signalHTML) ||
                standaloneSignOffIncludesInlineName(lowercasedHTML[signOffRange])
            ),
                  let postCIDHTML = htmlAfterFirstCIDBeforeNextSignOff(in: trailingHTML) else {
                return false
            }

            return hasSignatureContactOrRoleLine(in: signatureContactOrRoleLines(in: postCIDHTML))
        }
    }

    private static func htmlBeforeFirstCID(in html: String) -> String {
        guard let cidStart = indexBeforeFirstCIDReference(in: html) else {
            return html
        }

        return String(html[..<cidStart])
    }

    private static func indexBeforeFirstCIDReference(in html: String) -> String.Index? {
        guard let cidRange = html.range(of: "cid:") else {
            return nil
        }

        if isInsideHTMLTag(in: html, at: cidRange.lowerBound),
           let tagStart = html[..<cidRange.lowerBound].lastIndex(of: "<") {
            return tagStart
        }

        return cidRange.lowerBound
    }

    private static func htmlAfterFirstCIDBeforeNextSignOff(in html: String) -> String? {
        guard let postCIDStart = indexAfterFirstCIDReference(in: html) else {
            return nil
        }

        // A copy, as `Substring.range(of:options:)` searched one: the pattern's
        // `^` anchors to this slice, not to the enclosing document.
        let postCIDHTML = String(html[postCIDStart...])
        guard let nextSignOffRange = firstMatchRange(of: standaloneSignOffRegex, in: postCIDHTML) else {
            return postCIDHTML
        }

        return String(postCIDHTML[..<nextSignOffRange.lowerBound])
    }

    private static func indexAfterFirstCIDReference(in html: String) -> String.Index? {
        guard let cidRange = html.range(of: "cid:") else {
            return nil
        }

        if isInsideHTMLTag(in: html, at: cidRange.lowerBound),
           let tagEnd = html[cidRange.upperBound...].firstIndex(of: ">") {
            return html.index(after: tagEnd)
        }

        var index = cidRange.upperBound
        while index < html.endIndex {
            let character = html[index]
            if character == "\"" ||
                character == "'" ||
                character == ">" ||
                character == "<" ||
                character.isWhitespace {
                break
            }

            index = html.index(after: index)
        }

        return index
    }

    private static func isInsideHTMLTag(in html: String, at index: String.Index) -> Bool {
        let prefix = html[..<index]
        guard let openingTag = prefix.lastIndex(of: "<") else {
            return false
        }

        guard let closingTag = prefix.lastIndex(of: ">") else {
            return true
        }

        return openingTag > closingTag
    }

    private static func signatureIntroAllowsPostCIDContact(in html: String) -> Bool {
        let lines = signatureContactOrRoleLines(in: html)
        guard !lines.isEmpty, lines.count <= 3 else {
            return false
        }

        return lines.allSatisfy(isCompactSignatureIntroLine)
    }

    private static func standaloneSignOffIncludesInlineName(_ html: Substring) -> Bool {
        matches(standaloneSignOffWithInlineNameRegex, String(html))
    }

    private static func isCompactSignatureIntroLine(_ line: String) -> Bool {
        guard line.count <= 80,
              !line.contains("?"),
              !line.contains("!") else {
            return false
        }

        let words = line.split { !$0.isLetter && !$0.isNumber }
        guard words.count <= 6 else {
            return false
        }

        guard !isBodyProseLine(line) else {
            return false
        }

        if line.contains(".") {
            return isAbbreviatedSignatureRoleLine(line)
        }

        return true
    }

    private static func isAbbreviatedSignatureRoleLine(_ line: String) -> Bool {
        isSignatureRoleLine(line.replacingOccurrences(of: ".", with: ""))
    }

    private static func brandingSignalBelongsToSignature(in html: Substring) -> Bool {
        guard let brandingRange = earliestBrandingMarkerRange(in: html) else {
            return true
        }

        guard let cidRange = html.range(of: "cid:") else {
            return brandingSignalHasSignatureIntroBeforeBranding(
                in: html,
                brandingRange: brandingRange
            )
        }

        if brandingRange.lowerBound < cidRange.lowerBound {
            return brandingSignalHasSignatureIntroBeforeBranding(
                in: html,
                brandingRange: brandingRange
            )
        }

        let matchedHTML = String(html)
        let signalHTML = htmlBeforeFirstCID(in: matchedHTML)
        if !html[cidRange.lowerBound..<brandingRange.lowerBound].contains(">") {
            return signatureIntroAllowsPostCIDContact(in: signalHTML)
        }

        guard signatureIntroAllowsPostCIDContact(in: signalHTML),
              let postCIDHTML = htmlAfterFirstCIDBeforeNextSignOff(in: matchedHTML) else {
            return false
        }

        return signatureBrandingMarkers.contains { postCIDHTML.contains($0) }
    }

    private static func brandingSignalHasSignatureIntroBeforeBranding(
        in html: Substring,
        brandingRange: Range<Substring.Index>
    ) -> Bool {
        let brandingHTML = String(html[brandingRange.lowerBound...])
        guard let brandingLine = signatureContactOrRoleLines(in: brandingHTML).first,
              !isBodyProseLine(brandingLine) else {
            return false
        }

        // A copy, as `Substring.range(of:options:)` searched one: the pattern's
        // `^` anchors to this slice, not to the enclosing document.
        let prefix = String(html[..<brandingRange.lowerBound])
        guard let signOffRange = firstMatchRange(of: standaloneSignOffRegex, in: prefix) else {
            return false
        }

        if standaloneSignOffIncludesInlineName(prefix[signOffRange]) {
            return true
        }

        return signatureIntroAllowsPostCIDContact(in: String(prefix[signOffRange.upperBound...]))
    }

    private static func earliestBrandingMarkerRange(in html: Substring) -> Range<Substring.Index>? {
        signatureBrandingMarkers
            .compactMap { html.range(of: $0) }
            .min { lhs, rhs in
                lhs.lowerBound < rhs.lowerBound
            }
    }

    private static func standaloneSignOffRanges(
        in lowercasedHTML: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let searchRange = range ?? lowercasedHTML.startIndex..<lowercasedHTML.endIndex
        var searchStart = searchRange.lowerBound

        // One search per iteration from the previous match's end, never a
        // single `matches(in:range:)` pass: `^` in the pattern matches at the
        // start of the supplied range, so adjacent sign-offs
        // ("thanks,<br>regards,<br>") yield two ranges here and one there.
        while searchStart < searchRange.upperBound,
              let range = firstMatchRange(
                of: standaloneSignOffRegex,
                in: lowercasedHTML,
                range: searchStart..<searchRange.upperBound
              ) {
            ranges.append(range)
            searchStart = range.upperBound
        }

        return ranges
    }

    private static func regexRanges(
        of regex: NSRegularExpression?,
        in string: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let searchRange = range ?? string.startIndex..<string.endIndex
        var searchStart = searchRange.lowerBound

        // Same per-iteration search as standaloneSignOffRanges, for the same
        // `^`-at-range-start reason.
        while searchStart < searchRange.upperBound,
              let range = firstMatchRange(
                of: regex,
                in: string,
                range: searchStart..<searchRange.upperBound
              ) {
            ranges.append(range)
            searchStart = range.upperBound
        }

        return ranges
    }

    /// `String.range(of:options: .regularExpression, range:)` over a compiled
    /// pattern. NSRegularExpression's default bounds are opaque and anchoring,
    /// which is what that search used: `^`/`$` match at the supplied range's
    /// edges and lookaround cannot see outside it.
    private static func firstMatchRange(
        of regex: NSRegularExpression?,
        in string: String,
        range: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        guard let regex else { return nil }
        let searchRange = NSRange(range ?? string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: searchRange) else {
            return nil
        }
        return Range(match.range, in: string)
    }

    private static func matches(_ regex: NSRegularExpression?, _ string: String) -> Bool {
        firstMatchRange(of: regex, in: string) != nil
    }

    private static func replacingMatches(
        of regex: NSRegularExpression?,
        in string: String,
        with template: String
    ) -> String {
        guard let regex else { return string }
        return regex.stringByReplacingMatches(
            in: string,
            options: [],
            range: NSRange(string.startIndex..., in: string),
            withTemplate: template
        )
    }

    private static func signatureContactOrRoleLines(in trailingHTML: String) -> [String] {
        let linkAwareHTML = htmlExposingLinkTargets(from: trailingHTML)
        var lineSeparated = replacingMatches(of: lineBreakingTagRegex, in: linkAwareHTML, with: "\n")
        lineSeparated = replacingMatches(of: htmlTagRegex, in: lineSeparated, with: " ")
        lineSeparated = replacingMatches(of: nonBreakingSpaceEntityRegex, in: lineSeparated, with: " ")

        return lineSeparated
            .components(separatedBy: .newlines)
            .map { line in
                replacingMatches(of: whitespaceRunRegex, in: line, with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func htmlExposingLinkTargets(from html: String) -> String {
        guard let regex = linkTargetRegex else {
            return html
        }

        let matches = regex.matches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html)
        )
        guard !matches.isEmpty else {
            return html
        }

        var result = ""
        var cursor = html.startIndex
        for match in matches {
            guard let matchRange = Range(match.range(at: 0), in: html),
                  let valueRange = hrefValueRange(in: match, html: html) else {
                continue
            }

            result += html[cursor..<matchRange.lowerBound]
            result += " \(html[valueRange]) "
            cursor = matchRange.upperBound
        }
        result += html[cursor...]
        return result
    }

    private static func hrefValueRange(
        in match: NSTextCheckingResult,
        html: String
    ) -> Range<String.Index>? {
        for index in 1...3 {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let stringRange = Range(range, in: html) else {
                continue
            }
            return stringRange
        }

        return nil
    }

    private static func isSignatureContactLine(_ line: String) -> Bool {
        guard !isBodyProseLine(line) else {
            return false
        }

        if line.contains("mailto:") || line.contains("tel:") || line.contains("www.") {
            return true
        }

        if matches(emailAddressRegex, line) {
            return true
        }

        if matches(phoneOrAddressLabelRegex, line) {
            return true
        }

        if line.contains("unsubscribe") {
            return isUnsubscribeFooterLine(line)
        }

        return matches(socialNetworkLinkRegex, line)
    }

    private static func hasSignatureContactOrRoleLine(in lines: [String]) -> Bool {
        for index in lines.indices {
            if isSignatureContactLine(lines[index]) ||
                isSignatureRoleLine(lines[index]) ||
                isAbbreviatedSignatureRoleLine(lines[index]) {
                return true
            }

            let nextIndex = lines.index(after: index)
            if nextIndex < lines.endIndex,
               isSignatureContactLabelLine(lines[index]),
               isPhoneNumberLine(lines[nextIndex]) {
                return true
            }
        }

        return false
    }

    private static func isSignatureContactLabelLine(_ line: String) -> Bool {
        line == "mobile" || line == "phone"
    }

    private static func isPhoneNumberLine(_ line: String) -> Bool {
        matches(phoneNumberLineRegex, line)
    }

    private static func isUnsubscribeFooterLine(_ line: String) -> Bool {
        if line.contains("/unsubscribe") {
            return true
        }

        guard line.count <= 160 else {
            return false
        }

        return line == "unsubscribe" ||
            line.hasPrefix("unsubscribe ") ||
            line.hasSuffix(" unsubscribe") ||
            line.contains(" unsubscribe ")
    }

    private static func isBodyProseLine(_ line: String) -> Bool {
        let bodyProsePrefixes = [
            "please",
            "review",
            "here",
            "this",
            "that",
            "can",
            "could",
            "would",
            "i",
            "we",
            "you"
        ]
        guard !bodyProsePrefixes.contains(where: { line == $0 || line.hasPrefix($0 + " ") }) else {
            return true
        }

        if isBodyContactInstructionLine(line) {
            return true
        }

        let bodyContentWords = [
            "screenshot",
            "image",
            "figure",
            "photo",
            "diagram",
            "settings",
            "attached",
            "below"
        ]
        return bodyContentWords.contains { line.contains($0) }
    }

    private static func isBodyContactInstructionLine(_ line: String) -> Bool {
        matches(bodyContactInstructionRegex, line)
    }

    private static func isSignatureRoleLine(_ line: String) -> Bool {
        guard line.count <= 96,
              !line.contains("."),
              !line.contains("?"),
              !line.contains("!") else {
            return false
        }

        guard !isBodyProseLine(line) else {
            return false
        }

        return signatureRoleMarkerRegexes.contains { matches($0, line) }
    }

    private static func imageDimensions(in html: String, at cidStart: String.Index) -> (width: Int, height: Int)? {
        guard isInsideHTMLTag(in: html, at: cidStart),
              let tagStart = html[..<cidStart].lastIndex(of: "<"),
              let tagEnd = html[cidStart...].firstIndex(of: ">") else { return nil }
        let tag = String(html[tagStart...tagEnd])
        guard tag.hasPrefix("<img") else { return nil }

        func dimension(_ regex: NSRegularExpression?) -> Int? {
            guard let regex,
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let range = Range(match.range(at: 1), in: tag),
                  let value = Int(tag[range]), value > 0 else { return nil }
            return value
        }
        guard let width = dimension(imageWidthAttributeRegex),
              let height = dimension(imageHeightAttributeRegex) else { return nil }
        return (width, height)
    }

    private static func isLikelySignatureInlineAttachment(
        contentID: String,
        attachments: [MessageBubbleAttachmentSnapshot],
        htmlImageDimensions: (width: Int, height: Int)?,
        hasCorroboratedRegion: Bool,
        hasBrandingRegion: Bool,
        allowsDimensionOnlyClassification: Bool,
        usesExpandedHeuristics: Bool
    ) -> Bool {
        guard let attachment = attachments.first(where: { EmailDocument.normalizedContentID($0.contentId) == contentID }),
              attachment.mimeType.hasPrefix("image/") else { return false }

        // Filenames such as logo.png or award.jpg also describe authored content.
        // Require signature context even when the image's identity looks familiar.
        guard hasCorroboratedRegion || hasBrandingRegion else { return false }

        let filename = attachment.filename.lowercased()
        let contentIDLocalPart = contentID.split(separator: "@", maxSplits: 1).first.map(String.init) ?? contentID
        let identity = [filename, contentID, contentIDLocalPart].joined(separator: " ")
        let hasSignatureKeyword = signatureImageIdentityMarkers.contains { identity.contains($0) }
        let isGenerated = [filename, contentIDLocalPart].contains {
            matches(generatedInlineAssetRegex, $0)
        }
        if !usesExpandedHeuristics {
            let hasRegion = hasCorroboratedRegion || hasBrandingRegion
            let wasGenerated = [filename, contentIDLocalPart].contains {
                matches(sentGeneratedInlineAssetRegex, $0)
            }
            return hasRegion && (hasSignatureKeyword || (wasGenerated &&
                attachment.width > 0 && attachment.height > 0 &&
                attachment.width <= 900 && attachment.height <= 900))
        }
        if attachment.stateRaw == Attachment.State.failed.rawValue &&
            (attachment.width == 0 || attachment.height == 0) {
            return false // Preserve the existing retry affordance after a failed download.
        }
        let dimensions: (width: Int, height: Int)?
        if attachment.width > 0 && attachment.height > 0 {
            dimensions = (Int(attachment.width), Int(attachment.height))
        } else {
            dimensions = htmlImageDimensions
        }
        guard let dimensions else {
            // Unknown-size candidates still download through the bubble's
            // independent download trigger; large content reappears on update.
            return hasSignatureKeyword || (hasCorroboratedRegion && isGenerated)
        }
        let isBadge = dimensions.width <= 900 && dimensions.height <= 900
        // Keep the existing photo ceiling. Wide signature strips get a separate
        // height bound; a 1200 × 400 content photo does not qualify.
        let isBanner = dimensions.height <= 300 && dimensions.width / dimensions.height >= 3
        guard isBadge || isBanner else { return false }
        return hasSignatureKeyword || isGenerated || allowsDimensionOnlyClassification
    }

    /// Presentation may compact a surviving signature candidate, but ordinary
    /// pasted photos (including a bare thanks/name with no signature evidence)
    /// retain their existing size and chrome.
    private static func bodyInlineContentIDs(boundaries signatureBoundaries: SignatureBoundaryOffsets?) -> Set<String> {
        // Without a "cid:" reference `referencedContentIDs` is empty and the
        // scan below never fires, so the answer is the empty set.
        guard let signatureBoundaries else {
            return []
        }
        let lowercasedHTML = signatureBoundaries.lowercasedHTML
        let replyOffset = signatureBoundaries.replyBoundaryOffset
        let boundaries = [signatureBoundaries.hardSignatureBoundaryOffset, replyOffset] +
            signatureBoundaries.trailingSignatureStartOffsets.map(Optional.some)
        guard let firstBoundary = boundaries.compactMap({ $0 }).min() else {
            return EmailDocument.referencedContentIDs(in: lowercasedHTML)
        }
        let end = lowercasedHTML.index(lowercasedHTML.startIndex, offsetBy: firstBoundary)
        var bodyIDs = EmailDocument.referencedContentIDs(in: String(lowercasedHTML[..<end]))
        EmailDocument.scanReferencedContentIDs(in: lowercasedHTML) { cid, start in
            if hasFollowingBodyProse(in: lowercasedHTML, at: start, before: replyOffset) {
                bodyIDs.insert(cid)
            }
        }
        return bodyIDs
    }

    /// The boundary offsets `extractLikelySignatureInlineContentIDs` and
    /// `bodyInlineContentIDs` both key off, computed once per build from one
    /// lowercased copy of the HTML. Each used to lowercase the HTML and run
    /// the hard-boundary, reply-boundary and trailing-sign-off scans itself.
    private struct SignatureBoundaryOffsets {
        let lowercasedHTML: String
        let hardSignatureBoundaryOffset: Int?
        let replyBoundaryOffset: Int?
        /// Sorted, de-duplicated starts of the branding- and contact/role-
        /// corroborated standalone sign-offs before the reply boundary.
        let trailingSignatureStartOffsets: [Int]
        /// Starts of the contact/role-corroborated sign-offs, in match order.
        let corroboratedSignOffOffsets: [Int]
    }

    private static func signatureBoundaryOffsets(in lowercasedHTML: String) -> SignatureBoundaryOffsets {
        let replyBoundaryOffset = firstReplyBoundaryOffset(in: lowercasedHTML)
        let trailing = standaloneTrailingSignatureStartOffsets(in: lowercasedHTML, before: replyBoundaryOffset)
        return SignatureBoundaryOffsets(
            lowercasedHTML: lowercasedHTML,
            hardSignatureBoundaryOffset: firstHardSignatureBoundaryOffset(in: lowercasedHTML),
            replyBoundaryOffset: replyBoundaryOffset,
            trailingSignatureStartOffsets: trailing.trailingSignatureStartOffsets,
            corroboratedSignOffOffsets: trailing.corroboratedSignOffOffsets
        )
    }

    private static func supportsCalendarInvitePreviewCard(
        canonicalHTML: String,
        isForwardedEmail: Bool,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?
    ) -> Bool {
        guard !isForwardedEmail, isLikelyCalendarInvite else {
            return false
        }

        return CalendarInvitePreviewBuilder().canBuildPreview(
            canonicalHTML: canonicalHTML,
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            subject: subject
        )
    }

    private static func build(
        canonicalHTML: String?,
        parsedEmail: ParsedEmail?,
        hasHTMLSource: Bool,
        isForwardedEmail: Bool,
        isFromMe: Bool,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot]
    ) -> MessageBubbleHTMLAnalysis {
        guard let canonicalHTML else {
            return .placeholder(hasHTMLSource: hasHTMLSource)
        }

        // One lowercased copy and one boundary pass serve both the signature
        // classification and bodyInlineContentIDs. nil when the HTML holds no
        // "cid:" reference: both consumers answer [] then, as they did.
        let lowercasedHTML = canonicalHTML.lowercased()
        let signatureBoundaries = lowercasedHTML.contains("cid:")
            ? signatureBoundaryOffsets(in: lowercasedHTML)
            : nil

        return MessageBubbleHTMLAnalysis(
            hasHTMLSource: hasHTMLSource,
            referencedInlineContentIDs: extractReferencedContentIDs(
                from: canonicalHTML,
                parsedEmail: parsedEmail
            ),
            nonDisplayableInlineContentIDs: extractNonDisplayableInlineContentIDs(
                from: canonicalHTML,
                parsedEmail: parsedEmail,
                attachments: attachmentSnapshots,
                usesExpandedHeuristics: !isFromMe,
                signatureBoundaries: signatureBoundaries
            ),
            supportsCalendarInvitePreviewCard: supportsCalendarInvitePreviewCard(
                canonicalHTML: canonicalHTML,
                isForwardedEmail: isForwardedEmail,
                isLikelyCalendarInvite: isLikelyCalendarInvite,
                bodyText: bodyText,
                cleanedSnippet: cleanedSnippet,
                senderName: senderName,
                senderEmail: senderEmail,
                subject: subject
            ),
            bodyInlineContentIDs: bodyInlineContentIDs(boundaries: signatureBoundaries)
        )
    }

    // DOM subtrees whose inline images are quoted/signature assets by
    // containment alone. Limited to mail-client-generated, unambiguous
    // containers that actually *wrap the asset*, so the structural check never
    // depends on dimensions or filenames. Mirrors the high-confidence subset of
    // EmailDOMQuoteRemover's signature/quote selectors. Deliberately excludes:
    //   - the ambiguous author-authored `class="signature"` family (see
    //     authoredSignatureWrapperPatterns) and the substring footer selectors
    //     (`div[class*=sig]`), which would over-match a "Signature Collection"
    //     marketing block;
    //   - the bare/generic `blockquote`, which authors also use for visible
    //     pull-quotes (the quote remover still strips those when other content
    //     survives, so `removedByHTMLCleanup` covers the non-fallback case);
    //   - the marker-only `gmail_attr` / `moz-cite-prefix` / `OutlookMessageHeader`
    //     header divs, which hold the "On … wrote:" line but not the quoted
    //     images.
    private static let quotedOrSignatureContainerSelectors = [
        // Signature wrappers (mail-client generated)
        "div.gmail_signature",
        "div.gmail_signature_prefix",
        "div[data-smartmail=gmail_signature]",
        "div[class*=moz-signature]",
        "div[id*=ms-outlook-mobile-signature]",
        "div[class*=ms-outlook-mobile-signature]",
        "div.ms-outlook-signature",
        "div.AppleMailSignature",
        // Quoted-history containers that wrap the quoted body and its images
        "div.gmail_quote",
        "blockquote[type=cite]",
        "[id*=mail-editor-reference-message-container]"
    ]

    // Mail-client-generated signature wrappers — unambiguous, always a boundary.
    private static let trustedSignatureWrapperMarkers = [
        "gmail_signature",
        "moz-signature",
        "x-apple-signature",
        "data-smartmail=\"gmail_signature\""
    ]

    // Author-authored signature wrappers — exact `signature` class/id tokens only,
    // and only a boundary when corroborated by a nearby signature signal (see
    // firstCorroboratedAuthoredSignatureMarkerOffset).
    private static let authoredSignatureWrapperPatterns = [
        #"\bclass\s*=\s*"(?:signature(?=\s|")|[^"]*\ssignature(?=\s|"))"#,
        #"\bclass\s*=\s*'(?:signature(?=\s|')|[^']*\ssignature(?=\s|'))"#,
        #"\bid\s*=\s*"signature""#,
        #"\bid\s*=\s*'signature'"#
    ]

    // Match standalone reply headers without treating body prose like "here is
    // what I wrote:" or "On the whiteboard, Alice wrote:" as a hard
    // attachment-hiding boundary.
    private static let replyOnAttributionBoundaryPatterns = [
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:&gt;\s*)?on (?:(?!</?(?:div|p|td|th|li|blockquote|body|html)\b).){1,800}? wrote:\s*(?:<br\s*/?>|</(?:div|p|td|th|li|blockquote)>|[\r\n]|$)"#,
    ]

    private static let standaloneReplyAttributionBoundaryPatterns = [
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:&gt;\s*)?(?!(?:here|there|this|that|what|when|where|why|how|following|follow|i|we|you|he|she|they|it|someone|everyone|please|thanks|thank)\b)(?:[a-z][a-z0-9._%+\-']{0,60}\s+){0,2}[a-z][a-z0-9._%+\-']{0,60}(?:\s+&lt;[^&]{1,200}&gt;)?\s+wrote:\s*(?:<br\s*/?>|</(?:div|p|td|th|li|blockquote)>|[\r\n]|$)"#
    ]

    private static let replyAttributionDateOrEmailSignalPattern =
        #"\b(?:mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday|jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b|\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b|[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#

    // Match complete rich-text reply headers without treating isolated body
    // labels such as "<b>From:</b> the prototype table" as quote boundaries.
    private static let replyHeaderBoundaryPatterns = [
        #"<(?:b|strong)>\s*from:\s*</(?:b|strong)>[\s\S]{0,2400}<(?:b|strong)>\s*(?:sent|date):\s*</(?:b|strong)>[\s\S]{0,2400}<(?:b|strong)>\s*to:\s*</(?:b|strong)>[\s\S]{0,2400}<(?:b|strong)>\s*subject:\s*</(?:b|strong)>"#
    ]

    private static let signatureRoleMarkers = [
        "manager",
        "director",
        "president",
        "founder",
        "advisor",
        "broker",
        "realtor",
        "membership",
        "business development",
        "customer engineering"
    ]

    // Generic branding vocabulary only. Company-specific names (e.g. "cadence",
    // "fortune") over-match ordinary prose and must not be added here.
    private static let signatureBrandingMarkers = [
        "logo",
        "badge",
        "banner"
    ]

    private static let signatureSignalTrailingHTMLLimit = 8_000

    private static let standaloneSignOffBoundaryPattern =
        #"(?:<br\s*/?>|</(?:div|p|td|th|li)>|[\r\n]|$)"#

    private static let inlineSignOffNameBlockedWordsPattern =
        #"please|review|here|this|that|can|could|would|i|we|you|for|the|a|an|to|see|check|take|look|let|just|following|follow|all"#

    /// Word appends empty o:p paragraph marks after visible sign-off text.
    /// Match them in place so CID offsets remain in the original coordinate space.
    private static let htmlSignatureWhitespacePattern =
        #"(?:\s|&nbsp;|&#160;|<o:p\b[^>]*>|</o:p>)*"#

    private static let requiredHTMLSignatureWhitespacePattern =
        #"(?:\s|&nbsp;|&#160;)+"#

    private static let standaloneSignOffInlineOpeningTagsPattern =
        #"(?:<(?:span|strong|b|em|i|font|u|a)\b[^>]*>\#(htmlSignatureWhitespacePattern))*"#

    private static let standaloneSignOffInlineClosingTagsPattern =
        #"(?:\#(htmlSignatureWhitespacePattern)</(?:span|strong|b|em|i|font|u|a)>)*"#

    private static let inlineSignOffNameTokenPattern =
        #"\#(standaloneSignOffInlineOpeningTagsPattern)(?:[a-z]|(?!(?:\#(inlineSignOffNameBlockedWordsPattern))\b)[a-z](?:[a-z0-9._-]|'|&apos;|&#39;|&#x27;|&rsquo;){1,40})\#(standaloneSignOffInlineClosingTagsPattern)"#

    private static let inlineSignOffNamePattern =
        #"\#(inlineSignOffNameTokenPattern)(?:\#(requiredHTMLSignatureWhitespacePattern)\#(inlineSignOffNameTokenPattern)){0,3}"#

    private static let standaloneSignOffTailPattern =
        #"(?:[,.!]?\#(htmlSignatureWhitespacePattern)\#(standaloneSignOffInlineClosingTagsPattern)\#(htmlSignatureWhitespacePattern)\#(standaloneSignOffBoundaryPattern)|[,.!]\#(htmlSignatureWhitespacePattern)\#(standaloneSignOffInlineClosingTagsPattern)\#(htmlSignatureWhitespacePattern)\#(inlineSignOffNamePattern)\#(htmlSignatureWhitespacePattern)\#(standaloneSignOffInlineClosingTagsPattern)\#(htmlSignatureWhitespacePattern)\#(standaloneSignOffBoundaryPattern))"#

    private static let signOffAlternation = SignaturePatterns.signOffPhrases
        .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern(for:))
        .joined(separator: "|")

    private static let standaloneSignOffBeforeBrandingPattern =
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:\#(signOffAlternation))\#(standaloneSignOffTailPattern)[\s\S]{0,\#(signatureSignalTrailingHTMLLimit)}(?:\#(signatureBrandingMarkers.joined(separator: "|")))"#

    private static let standaloneSignOffWithInlineNamePattern =
        #"(?:\#(signOffAlternation))[,.!]\#(htmlSignatureWhitespacePattern)\#(standaloneSignOffInlineClosingTagsPattern)\#(htmlSignatureWhitespacePattern)\#(inlineSignOffNamePattern)"#

    private static let standaloneSignOffPattern =
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:\#(signOffAlternation))\#(standaloneSignOffTailPattern)"#

    // Generated inline asset names (Outlook/Word image001.png, hex content-IDs).
    // Require at least one digit so hex-letter words like "imageface.png" are
    // not misread as generated assets.
    private static let generatedInlineAssetPattern =
        #"^(?:(?:image|inline|cid)(?=[0-9a-f_-]*[0-9])[0-9a-f_-]{1,}|ii_[0-9a-z]{6,}|pastedgraphic-\d+|outlook-[0-9a-z]{6,}|part\d+\.[0-9a-f]+\.[0-9a-f]+)(?:\.[a-z0-9]{2,5})?$"#

    private static let signatureImageIdentityMarkers = [
        "logo",
        "signature",
        "footer",
        "banner",
        "badge",
        "award",
        "linkedin",
        "twitter",
        "facebook",
        "instagram",
        "social",
        "unsubscribe"
    ]

    // MARK: - Compiled patterns

    // Every pattern above used to compile per call, several inside per-line
    // and per-match loops, on each attachment-bearing bubble's first content
    // load. Compiled once here with no options: every call site searched with
    // `range(of:options: .regularExpression)` or `NSRegularExpression(pattern:)`
    // without `.caseInsensitive` (the HTML is lowercased first), and the
    // templates are the same literal strings. NSRegularExpression is immutable
    // and thread-safe. A nil entry (compile failure) behaves as the per-call
    // `try?` did: no match, or the input returned unchanged.

    private static let authoredSignatureWrapperRegexes: [NSRegularExpression] =
        authoredSignatureWrapperPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static let replyOnAttributionBoundaryRegexes: [NSRegularExpression] =
        replyOnAttributionBoundaryPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static let standaloneReplyAttributionBoundaryRegexes: [NSRegularExpression] =
        standaloneReplyAttributionBoundaryPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static let replyHeaderBoundaryRegexes: [NSRegularExpression] =
        replyHeaderBoundaryPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static let replyAttributionDateOrEmailSignalRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: replyAttributionDateOrEmailSignalPattern)
    }()

    private static let standaloneSignOffBeforeBrandingRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: standaloneSignOffBeforeBrandingPattern)
    }()

    private static let standaloneSignOffWithInlineNameRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: standaloneSignOffWithInlineNamePattern)
    }()

    private static let standaloneSignOffRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: standaloneSignOffPattern)
    }()

    private static let generatedInlineAssetRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: generatedInlineAssetPattern)
    }()

    /// The narrower generated-asset shape the sent-message (non-expanded)
    /// identity gate in `isLikelySignatureInlineAttachment` keeps.
    private static let sentGeneratedInlineAssetRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:image|img|inline|cid)(?=[0-9a-f_-]*[0-9])[0-9a-f_-]{2,}(?:\.[a-z0-9]{2,5})?$"#
        )
    }()

    /// One `\b…\b` regex per `signatureRoleMarkers` entry, as
    /// `isSignatureRoleLine` built per marker per line.
    private static let signatureRoleMarkerRegexes: [NSRegularExpression] = signatureRoleMarkers.compactMap { marker in
        try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: marker))\\b")
    }

    private static let imageWidthAttributeRegex = imageDimensionAttributeRegex(named: "width")

    private static let imageHeightAttributeRegex = imageDimensionAttributeRegex(named: "height")

    private static func imageDimensionAttributeRegex(named name: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: #"\s\#(name)\s*=\s*["']?(\d+)(?:["'\s>])"#)
    }

    private static let lineBreakingTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<br\s*/?>|</(?:div|p|td|th|li|tr|table)>"#)
    }()

    private static let htmlTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<[^>]+>"#)
    }()

    private static let nonBreakingSpaceEntityRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"&nbsp;|&#160;"#)
    }()

    private static let whitespaceRunRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s+"#)
    }()

    private static let linkTargetRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>"#)
    }()

    private static let emailAddressRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#)
    }()

    private static let phoneOrAddressLabelRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b(?:mobile|phone)\b\s*(?::|\+|[0-9(])|\baddress\s*:"#)
    }()

    private static let socialNetworkLinkRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b(?:linkedin|instagram|twitter)\b(?:\.com|/|:)"#)
    }()

    private static let phoneNumberLineRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(?:\+|[0-9(])[\d\s().\-]{5,}$"#)
    }()

    private static let bodyContactInstructionRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\bemail\s+[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\s+(?:if|when|so|to|for|about|with)\b"#
        )
    }()
}
