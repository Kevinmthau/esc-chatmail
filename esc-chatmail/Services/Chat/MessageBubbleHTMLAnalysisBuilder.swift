import Foundation

enum MessageBubbleHTMLAnalysisBuilder {
    static func build(
        canonicalHTML: String?,
        parsedEmail: ParsedEmail? = nil,
        hasHTMLSourceHint: Bool,
        isForwardedEmail: Bool,
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
        attachments: [MessageBubbleAttachmentSnapshot]
    ) -> Set<String> {
        guard let html else { return [] }

        let originalReferenced = extractReferencedContentIDs(from: html, parsedEmail: parsedEmail)
        guard !originalReferenced.isEmpty else { return [] }

        let cleaned = cleanedHTMLForAttachmentFiltering(from: html)
        let cleanedReferenced = extractReferencedContentIDs(from: cleaned)
        let removedByHTMLCleanup = originalReferenced.subtracting(cleanedReferenced)
        let likelySignatureInline = extractLikelySignatureInlineContentIDs(
            from: html,
            attachments: attachments
        )

        return removedByHTMLCleanup.union(likelySignatureInline)
    }

    private static func cleanedHTMLForAttachmentFiltering(from html: String) -> String {
        let quotedAndSignature = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedAndSignature) {
            return quotedAndSignature
        }

        let quotedOnly = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedOnly) {
            return quotedOnly
        }

        return html
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
        from html: String,
        attachments: [MessageBubbleAttachmentSnapshot]
    ) -> Set<String> {
        let lowercasedHTML = html.lowercased()
        guard lowercasedHTML.contains("cid:") else {
            return []
        }

        let hardSignatureBoundaryOffset = firstHardSignatureBoundaryOffset(in: lowercasedHTML)
        let replyBoundaryOffset = firstReplyBoundaryOffset(in: lowercasedHTML)
        let trailingSignatureStartOffsets = standaloneTrailingSignatureStartOffsets(
            in: lowercasedHTML,
            before: replyBoundaryOffset
        )
        let hasTrailingSignatureSignals =
            !trailingSignatureStartOffsets.isEmpty
        let hasSignatureSectionSignals =
            hardSignatureBoundaryOffset != nil ||
            replyBoundaryOffset != nil ||
            hasTrailingSignatureSignals

        guard hasSignatureSectionSignals else {
            return []
        }

        var nonDisplayable = Set<String>()
        EmailDocument.scanReferencedContentIDs(in: html) { normalizedCID, valueStart in
            let cidOffset = html.distance(from: html.startIndex, to: valueStart)

            let isAfterHardSignatureBoundary = hardSignatureBoundaryOffset.map { cidOffset >= $0 } ?? false
            let isAfterReplyBoundary = replyBoundaryOffset.map { cidOffset >= $0 } ?? false
            let isAfterStandaloneSignatureBoundary = trailingSignatureStartOffsets.contains { cidOffset >= $0 }
            let hasStrongGeneratedBadgeContext =
                isAfterHardSignatureBoundary ||
                isAfterReplyBoundary ||
                isAfterStandaloneSignatureBoundary

            guard isAfterHardSignatureBoundary ||
                    isAfterReplyBoundary ||
                    isAfterStandaloneSignatureBoundary else {
                return
            }

            guard isLikelySignatureInlineAttachment(
                contentID: normalizedCID,
                attachments: attachments,
                allowGeneratedBadgeDimensions: hasStrongGeneratedBadgeContext
            ) else {
                return
            }

            nonDisplayable.insert(normalizedCID)
        }

        return nonDisplayable
    }

    private static func firstHardSignatureBoundaryOffset(in lowercasedHTML: String) -> Int? {
        signatureHardBoundaryMarkers.compactMap { marker -> Int? in
            guard let range = lowercasedHTML.range(of: marker) else { return nil }
            return lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: range.lowerBound)
        }.min()
    }

    private static func firstReplyBoundaryOffset(in lowercasedHTML: String) -> Int? {
        var candidates: [Int] = []
        for pattern in replyAttributionBoundaryPatterns {
            if let replyAttributionRange = lowercasedHTML.range(
                of: pattern,
                options: .regularExpression
            ) {
                let replyAttributionOffset = lowercasedHTML.distance(
                    from: lowercasedHTML.startIndex,
                    to: replyAttributionRange.lowerBound
                )
                candidates.append(replyAttributionOffset)
            }
        }

        for pattern in replyHeaderBoundaryPatterns {
            if let replyHeaderRange = lowercasedHTML.range(
                of: pattern,
                options: .regularExpression
            ) {
                let replyHeaderOffset = lowercasedHTML.distance(
                    from: lowercasedHTML.startIndex,
                    to: replyHeaderRange.lowerBound
                )
                candidates.append(replyHeaderOffset)
            }
        }

        return candidates.min()
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

    private static func standaloneTrailingSignatureStartOffsets(
        in lowercasedHTML: String,
        before offset: Int?
    ) -> [Int] {
        let searchRange = signatureSignalSearchRange(in: lowercasedHTML, before: offset)
        let ranges =
            standaloneSignOffBrandingRanges(in: lowercasedHTML, range: searchRange) +
            standaloneSignOffContactOrRoleRanges(in: lowercasedHTML, range: searchRange)
        let offsets = ranges.map { range in
            lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: range.lowerBound)
        }
        return Array(Set(offsets)).sorted()
    }

    private static func standaloneSignOffBrandingRanges(
        in lowercasedHTML: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        regexRanges(
            of: standaloneSignOffBeforeBrandingPattern,
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

        let postCIDHTML = html[postCIDStart...]
        guard let nextSignOffRange = postCIDHTML.range(
            of: standaloneSignOffPattern,
            options: .regularExpression
        ) else {
            return String(postCIDHTML)
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
        html.range(
            of: standaloneSignOffWithInlineNamePattern,
            options: .regularExpression
        ) != nil
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

        let prefix = html[..<brandingRange.lowerBound]
        guard let signOffRange = prefix.range(
            of: standaloneSignOffPattern,
            options: .regularExpression
        ) else {
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

        while searchStart < searchRange.upperBound,
              let range = lowercasedHTML.range(
                of: standaloneSignOffPattern,
                options: .regularExpression,
                range: searchStart..<searchRange.upperBound
              ) {
            ranges.append(range)
            searchStart = range.upperBound
        }

        return ranges
    }

    private static func regexRanges(
        of pattern: String,
        in string: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let searchRange = range ?? string.startIndex..<string.endIndex
        var searchStart = searchRange.lowerBound

        while searchStart < searchRange.upperBound,
              let range = string.range(
                of: pattern,
                options: .regularExpression,
                range: searchStart..<searchRange.upperBound
              ) {
            ranges.append(range)
            searchStart = range.upperBound
        }

        return ranges
    }

    private static func signatureContactOrRoleLines(in trailingHTML: String) -> [String] {
        let linkAwareHTML = htmlExposingLinkTargets(from: trailingHTML)
        let lineSeparated = linkAwareHTML
            .replacingOccurrences(
                of: #"<br\s*/?>|</(?:div|p|td|th|li|tr|table)>"#,
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"&nbsp;|&#160;"#,
                with: " ",
                options: .regularExpression
            )

        return lineSeparated
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func htmlExposingLinkTargets(from html: String) -> String {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
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

        if line.range(
            of: #"[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if line.range(
            of: #"\b(?:mobile|phone)\b\s*(?::|\+|[0-9(])|\baddress\s*:"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if line.contains("unsubscribe") {
            return isUnsubscribeFooterLine(line)
        }

        return line.range(
            of: #"\b(?:linkedin|instagram|twitter)\b(?:\.com|/|:)"#,
            options: .regularExpression
        ) != nil
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
        line.range(
            of: #"^(?:\+|[0-9(])[\d\s().\-]{5,}$"#,
            options: .regularExpression
        ) != nil
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
        line.range(
            of: #"\bemail\s+[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\s+(?:if|when|so|to|for|about|with)\b"#,
            options: .regularExpression
        ) != nil
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

        return signatureRoleMarkers.contains { marker in
            line.range(
                of: "\\b\(NSRegularExpression.escapedPattern(for: marker))\\b",
                options: .regularExpression
            ) != nil
        }
    }

    private static func isLikelySignatureInlineAttachment(
        contentID: String,
        attachments: [MessageBubbleAttachmentSnapshot],
        allowGeneratedBadgeDimensions: Bool
    ) -> Bool {
        guard let attachment = attachments.first(where: { EmailDocument.normalizedContentID($0.contentId) == contentID }) else {
            return false
        }

        guard attachment.mimeType.hasPrefix("image/") else {
            return false
        }

        let filename = attachment.filename.lowercased()
        let contentIDLocalPart = contentID
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? contentID
        let searchableIdentity = [filename, contentID, contentIDLocalPart].joined(separator: " ")
        let hasSignatureKeyword = signatureImageIdentityMarkers.contains { searchableIdentity.contains($0) }

        let isGeneratedInlineName = filename.range(
            of: generatedInlineAssetPattern,
            options: .regularExpression
        ) != nil

        let isGeneratedInlineContentID = contentIDLocalPart.range(
            of: generatedInlineAssetPattern,
            options: .regularExpression
        ) != nil

        let hasSmallLogoLikeDimensions =
            attachment.width > 0 &&
            attachment.height > 0 &&
            attachment.width >= attachment.height &&
            attachment.width <= 420 &&
            attachment.height <= 160

        let hasBadgeLikeDimensions =
            attachment.width > 0 &&
            attachment.height > 0 &&
            attachment.width <= 900 &&
            attachment.height <= 900

        let looksLikeGeneratedInlineAsset = isGeneratedInlineName || isGeneratedInlineContentID
        return hasSignatureKeyword ||
            (
                looksLikeGeneratedInlineAsset &&
                (
                    hasSmallLogoLikeDimensions ||
                    (allowGeneratedBadgeDimensions && hasBadgeLikeDimensions)
                )
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

        return MessageBubbleHTMLAnalysis(
            hasHTMLSource: hasHTMLSource,
            referencedInlineContentIDs: extractReferencedContentIDs(
                from: canonicalHTML,
                parsedEmail: parsedEmail
            ),
            nonDisplayableInlineContentIDs: extractNonDisplayableInlineContentIDs(
                from: canonicalHTML,
                parsedEmail: parsedEmail,
                attachments: attachmentSnapshots
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
            )
        )
    }

    private static let signatureHardBoundaryMarkers = [
        "gmail_signature",
        "moz-signature",
        "x-apple-signature",
        "data-smartmail=\"gmail_signature\"",
        "class=\"signature",
        "class='signature",
        "id=\"signature",
        "id='signature"
    ]

    // Match standalone reply headers without treating body prose like
    // "here is what I wrote:" as a hard attachment-hiding boundary.
    private static let replyAttributionBoundaryPatterns = [
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:&gt;\s*)?on (?:(?!</?(?:div|p|td|th|li|blockquote|body|html)\b).){1,800}? wrote:\s*(?:<br\s*/?>|</(?:div|p|td|th|li|blockquote)>|[\r\n]|$)"#,
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:&gt;\s*)?(?!(?:here|there|this|that|what|when|where|why|how|following|follow|i|we|you|he|she|they|it|someone|everyone|please|thanks|thank)\b)(?:[a-z][a-z0-9._%+\-']{0,60}\s+){0,2}[a-z][a-z0-9._%+\-']{0,60}(?:\s+&lt;[^&]{1,200}&gt;)?\s+wrote:\s*(?:<br\s*/?>|</(?:div|p|td|th|li|blockquote)>|[\r\n]|$)"#
    ]

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

    private static let signatureBrandingMarkers = [
        "logo",
        "badge",
        "banner",
        "fortune",
        "best companies",
        "cadence",
        "unleash imagination"
    ]

    private static let signatureSignalTrailingHTMLLimit = 8_000

    private static let standaloneSignOffBoundaryPattern =
        #"(?:<br\s*/?>|</(?:div|p|td|th|li)>|[\r\n]|$)"#

    private static let inlineSignOffNameBlockedWordsPattern =
        #"please|review|here|this|that|can|could|would|i|we|you|for|the|a|an|to|see|check|take|look|let|just|following|follow|all"#

    private static let htmlSignatureWhitespacePattern =
        #"(?:\s|&nbsp;|&#160;)*"#

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

    private static let standaloneSignOffBeforeBrandingPattern =
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:warmly|best regards|kind regards|regards|sincerely|thanks|thank you|cheers)\#(standaloneSignOffTailPattern)[\s\S]{0,\#(signatureSignalTrailingHTMLLimit)}(?:logo|badge|banner|fortune|best companies|cadence|unleash imagination)"#

    private static let standaloneSignOffWithInlineNamePattern =
        #"(?:warmly|best regards|kind regards|regards|sincerely|thanks|thank you|cheers)[,.!]\#(htmlSignatureWhitespacePattern)\#(standaloneSignOffInlineClosingTagsPattern)\#(htmlSignatureWhitespacePattern)\#(inlineSignOffNamePattern)"#

    private static let standaloneSignOffPattern =
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:warmly|best regards|kind regards|regards|sincerely|thanks|thank you|cheers)\#(standaloneSignOffTailPattern)"#

    // Generated inline asset names (Outlook/Word image001.png, hex content-IDs).
    // Require at least one digit so hex-letter words like "imageface.png" are
    // not misread as generated assets.
    private static let generatedInlineAssetPattern =
        #"^(?:image|img|inline|cid)(?=[0-9a-f_-]*[0-9])[0-9a-f_-]{2,}(?:\.[a-z0-9]{2,5})?$"#

    private static let signatureImageIdentityMarkers = [
        "logo",
        "signature",
        "footer",
        "banner",
        "badge",
        "award",
        "fortune",
        "best-companies",
        "bestcompanies",
        "cadence",
        "linkedin",
        "twitter",
        "facebook",
        "instagram",
        "social",
        "unsubscribe"
    ]
}
