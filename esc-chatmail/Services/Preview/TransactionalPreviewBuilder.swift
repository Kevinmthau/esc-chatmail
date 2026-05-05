import Foundation

struct TransactionalPreviewBuilder {
    private let imageExtractor = EmailPreviewImageExtractor()
    private let urlSanitizer = HTMLURLSanitizer()
    private let trackingRemover = HTMLTrackingRemover()

    func buildPreview(
        canonicalHTML: String,
        bodyText: String?,
        cleanedSnippet: String? = nil,
        senderName: String? = nil,
        senderEmail: String?,
        subject: String? = nil
    ) -> TransactionalPreviewModel? {
        let extractedContent = EmailPreviewContentExtractor.extract(
            canonicalHTML: canonicalHTML,
            bodyText: bodyText,
            imageExtractor: imageExtractor
        )

        return buildPreview(
            canonicalHTML: canonicalHTML,
            plainText: extractedContent.plainText,
            extractedText: extractedContent.htmlText,
            extractedImages: extractedContent.images,
            htmlSummary: extractedContent.htmlSummary,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    func buildPreview(
        source: EmailPreviewSource,
        cleanedSnippet: String? = nil,
        senderName: String? = nil,
        senderEmail: String?,
        subject: String? = nil
    ) -> TransactionalPreviewModel? {
        guard let canonicalHTML = source.canonicalHTML else {
            return nil
        }

        return buildPreview(
            canonicalHTML: canonicalHTML,
            plainText: source.plainText,
            extractedText: source.extractedText,
            extractedImages: source.extractedImages,
            htmlSummary: source.htmlSummary,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    private func buildPreview(
        canonicalHTML: String,
        plainText: String?,
        extractedText: String?,
        extractedImages: [EmailPreviewImage],
        htmlSummary: EmailPreviewHTMLSummary,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?
    ) -> TransactionalPreviewModel? {
        let sourceDomain = normalizedSourceDomain(from: senderEmail)
        let sourceLabel = sourceLabel(senderName: senderName, sourceDomain: sourceDomain)
        let lines = cleanedPreviewLines(
            plainText: plainText,
            canonicalHTML: canonicalHTML,
            extractedText: extractedText
        )
        let detailFields = detailFields(from: lines)
        let title = resolvedTitle(from: htmlSummary, subject: subject, lines: lines, sourceLabel: sourceLabel)
        let amount = resolvedAmount(
            subject: subject,
            cleanedSnippet: cleanedSnippet,
            lines: lines,
            extractedText: extractedText
        )
        let subtitle = resolvedSubtitle(
            cleanedSnippet: cleanedSnippet,
            from: lines,
            excluding: [title, amount, sourceLabel, sourceDomain]
        )
        let status = resolvedStatus(from: detailFields, lines: lines, excluding: [title, subtitle])
        let detailLine = resolvedDetailLine(
            from: detailFields,
            lines: lines,
            status: status,
            excluding: [title, subtitle, amount, sourceLabel, sourceDomain]
        )
        let actionLabel = resolvedActionLabel(from: htmlSummary)
        let image = bestImageCandidate(from: extractedImages)

        guard title != nil || amount != nil || subtitle != nil || detailLine != nil else {
            return nil
        }

        let normalizedSubject = sanitizedTransactionTitle(subject)
        let resolvedTitle = title ?? normalizedSubject ?? sourceLabel ?? "Transaction update"

        return TransactionalPreviewModel(
            title: resolvedTitle,
            subtitle: subtitle,
            amount: amount,
            status: status,
            actionLabel: actionLabel,
            detailLine: detailLine,
            imageURL: image?.url,
            imageStyle: image?.style ?? .avatar,
            sourceLabel: sourceLabel,
            sourceDomain: sourceDomain
        )
    }

    private func resolvedTitle(
        from htmlSummary: EmailPreviewHTMLSummary,
        subject: String?,
        lines: [String],
        sourceLabel: String?
    ) -> String? {
        let candidates = [
            sanitizedTransactionTitle(subject),
            transactionLine(from: lines, excluding: [sourceLabel]),
            sanitizedTransactionTitle(htmlSummary.h1Text),
            sanitizedTransactionTitle(htmlSummary.h2Text),
            sanitizedTransactionTitle(htmlSummary.titleText),
            sanitizedTransactionTitle(htmlSummary.preheaderText)
        ]

        for candidate in candidates {
            guard let candidate, isMeaningfulTitle(candidate) else {
                continue
            }
            return truncate(candidate, limit: 90)
        }

        return nil
    }

    private func resolvedAmount(
        subject: String?,
        cleanedSnippet: String?,
        lines: [String],
        extractedText: String? = nil
    ) -> String? {
        let candidates: [String?] = [
            subject,
            cleanedSnippet,
            lines.joined(separator: "\n"),
            normalizedPreviewText(extractedText)
        ]

        for candidate in candidates {
            if let amount = firstAmount(in: candidate) {
                return amount
            }
        }

        return nil
    }

    private func resolvedSubtitle(
        cleanedSnippet: String?,
        from lines: [String],
        excluding excluded: [String?]
    ) -> String? {
        let excludedValues = normalizedSet(from: excluded)

        if let cleanedSnippet = normalizedCandidateLine(cleanedSnippet),
           !excludedValues.contains(normalizedComparableText(cleanedSnippet)),
           !restatesExcludedContent(cleanedSnippet, excluded: excluded),
           cleanedSnippet.count >= 14 {
            return truncate(cleanedSnippet, limit: 90)
        }

        if let reservationSubtitle = resolvedReservationSubtitle(from: lines, excluding: excludedValues) {
            return reservationSubtitle
        }

        for line in lines {
            guard let candidate = normalizedCandidateLine(line) else {
                continue
            }

            let comparable = normalizedComparableText(candidate)
            guard !excludedValues.contains(comparable),
                  !restatesExcludedContent(candidate, excluded: excluded),
                  candidate.count >= 14,
                  candidate.count <= 90,
                  !looksLikeDateOrStatus(candidate),
                  !isDetailFieldLabel(candidate),
                  containsLetter(candidate) else {
                continue
            }

            return truncate(candidate, limit: 90)
        }

        return nil
    }

    private func resolvedStatus(
        from detailFields: [String: String],
        lines: [String],
        excluding excluded: [String?]
    ) -> String? {
        if let status = normalizedStatus(detailFields["status"]) {
            return status
        }

        let excludedValues = normalizedSet(from: excluded)
        for line in lines {
            let comparable = normalizedComparableText(line)
            guard !excludedValues.contains(comparable),
                  let status = normalizedStatus(line) else {
                continue
            }
            return status
        }

        let combinedText = lines.joined(separator: "\n").lowercased()
        if combinedText.contains("reservation has been cancelled") ||
            combinedText.contains("reservation has been canceled") {
            return "Cancelled"
        }

        return nil
    }

    private func resolvedDetailLine(
        from detailFields: [String: String],
        lines: [String],
        status: String?,
        excluding excluded: [String?]
    ) -> String? {
        var segments: [String] = []

        if let date = normalizedCandidateLine(detailFields["date"]) {
            segments.append(date)
        }

        if let paymentMethod = normalizedCandidateLine(detailFields["paymentMethod"]) {
            segments.append(paymentMethod)
        } else if let sentFrom = normalizedCandidateLine(detailFields["sentFrom"]) {
            segments.append(sentFrom)
        }

        if let merchant = normalizedCandidateLine(detailFields["merchant"]) {
            segments.append(merchant)
        }

        if !segments.isEmpty {
            return truncate(segments.prefix(2).joined(separator: " • "), limit: 90)
        }

        if let reservationDetailLine = resolvedReservationDetailLine(from: lines) {
            return reservationDetailLine
        }

        let excludedValues = normalizedSet(from: excluded + [status])
        for line in lines {
            guard let candidate = normalizedCandidateLine(line) else {
                continue
            }

            let comparable = normalizedComparableText(candidate)
            guard !excludedValues.contains(comparable),
                  !restatesExcludedContent(candidate, excluded: excluded + [status]),
                  !looksLikeDateOrStatus(candidate),
                  !isDetailFieldLabel(candidate),
                  candidate.count >= 10,
                  containsLetter(candidate) else {
                continue
            }

            return truncate(candidate, limit: 90)
        }

        return nil
    }

    private func resolvedActionLabel(from htmlSummary: EmailPreviewHTMLSummary) -> String? {
        for candidate in htmlSummary.actionLinkTexts {
            guard !candidate.isEmpty else {
                continue
            }

            let lowercased = candidate.lowercased()
            guard !ignoredActionPatterns.contains(where: lowercased.contains) else {
                continue
            }

            if preferredActionPatterns.contains(where: lowercased.contains) {
                return truncate(candidate, limit: 32)
            }

        }

        return nil
    }

    private func cleanedPreviewLines(
        plainText: String?,
        canonicalHTML: String,
        extractedText: String? = nil
    ) -> [String] {
        let bodyLines = previewLines(from: plainText ?? "")
        let htmlText = normalizedPreviewText(extractedText)
            ?? normalizedText(TextProcessing.extractPlainText(from: canonicalHTML))
        let htmlLines = previewLines(from: htmlText)

        guard !bodyLines.isEmpty else {
            return htmlLines
        }

        guard !htmlLines.isEmpty else {
            return bodyLines
        }

        let bodyScore = transactionalQualityScore(for: bodyLines)
        let htmlScore = transactionalQualityScore(for: htmlLines)
        return htmlScore >= bodyScore + 4 ? htmlLines : bodyLines
    }

    private func previewLines(from rawText: String) -> [String] {
        guard !rawText.isEmpty else { return [] }

        let rawLines = rawText.components(separatedBy: .newlines)
        var lines: [String] = []

        for line in rawLines {
            let normalizedLine = normalizedText(line)
            guard !normalizedLine.isEmpty else {
                continue
            }

            if shouldStopAtFooter(normalizedLine), !lines.isEmpty {
                break
            }

            if shouldSkipLine(normalizedLine) {
                continue
            }

            let comparable = normalizedComparableText(normalizedLine)
            if lines.contains(where: { normalizedComparableText($0) == comparable }) {
                continue
            }

            lines.append(normalizedLine)

            if lines.count >= 28 {
                break
            }
        }

        return lines
    }

    private func transactionalQualityScore(for lines: [String]) -> Int {
        var score = 0
        let joined = lines.joined(separator: "\n").lowercased()

        if firstAmount(in: joined) != nil {
            score += 24
        }

        if transactionLine(from: lines, excluding: []) != nil {
            score += 22
        }

        if joined.contains("status") {
            score += 8
        }

        if joined.contains("date") {
            score += 8
        }

        if joined.contains("transaction details") || joined.contains("order details") {
            score += 8
        }

        if lines.count >= 4 {
            score += 6
        }

        return score
    }

    private func detailFields(from lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]

        for index in 0..<max(lines.count - 1, 0) {
            let label = lines[index]
            let value = lines[index + 1]

            guard let key = canonicalDetailField(for: label),
                  !isDetailFieldLabel(value),
                  !shouldSkipLine(value),
                  fields[key] == nil else {
                continue
            }

            fields[key] = value
        }

        return fields
    }

    private func canonicalDetailField(for label: String) -> String? {
        let lowercased = normalizedComparableText(label)

        for (key, patterns) in detailFieldPatterns {
            if patterns.contains(where: lowercased.contains) {
                return key
            }
        }

        return nil
    }

    private func transactionLine(from lines: [String], excluding excluded: [String?]) -> String? {
        let excludedValues = normalizedSet(from: excluded)

        for line in lines {
            let comparable = normalizedComparableText(line)
            guard !excludedValues.contains(comparable),
                  looksLikeTransactionalTitle(line) else {
                continue
            }

            return line
        }

        return nil
    }

    private func looksLikeTransactionalTitle(_ line: String) -> Bool {
        let lowercased = normalizedComparableText(line)

        guard line.count >= 8,
              !transactionalPromotionalPatterns.contains(where: lowercased.contains),
              !isDetailFieldLabel(line) else {
            return false
        }

        if transactionalTitlePatterns.contains(where: lowercased.contains) {
            return true
        }

        return lowercased.contains("payment") && firstAmount(in: line) != nil
    }

    private func bestImageCandidate(from images: [EmailPreviewImage]) -> TransactionalImageCandidate? {
        var bestCandidate: TransactionalImageCandidate?

        for image in images.prefix(12) {
            let width = image.width
            let height = image.height
            let descriptor = image.descriptor

            guard let safeURL = safeImageURL(
                from: image.sourceURL,
                descriptor: descriptor,
                width: width,
                height: height
            ) else {
                continue
            }

            let lowercasedURL = safeURL.lowercased()
            let aspectRatio = aspectRatio(width: width, height: height)
            let looksSquare = aspectRatio.map { $0 >= 0.8 && $0 <= 1.25 } ?? false
            let impliesAvatar =
                descriptor.contains("profile") ||
                descriptor.contains("avatar") ||
                lowercasedURL.contains("pics-v") ||
                lowercasedURL.contains("profile") ||
                lowercasedURL.contains("avatar")
            let isAvatarLike =
                (looksSquare &&
                 min(width ?? 0, height ?? 0) >= 40 &&
                 max(width ?? 0, height ?? 0) <= 160) ||
                (impliesAvatar &&
                 width.map { $0 > 36 } != false &&
                 height.map { $0 > 36 } != false)

            var score = 0

            if isAvatarLike {
                score += 28
            }

            if descriptor.contains("profile") || descriptor.contains("avatar") {
                score += 22
            }

            if descriptor.contains(" image") {
                score += 14
            }

            if lowercasedURL.contains("pics") || lowercasedURL.contains("profile") || lowercasedURL.contains("avatar") {
                score += 16
            }

            if let aspectRatio, aspectRatio > 1.8 {
                score -= 26
            }

            if descriptor.contains("logo") || descriptor.contains("wordmark") {
                score -= 20
            }

            if let width, width < 36 {
                score -= 16
            }

            if let height, height < 36 {
                score -= 16
            }

            let style: TransactionalPreviewImageStyle
            if isAvatarLike || impliesAvatar {
                style = .avatar
            } else if looksSquare {
                style = .card
                score += 6
            } else {
                continue
            }

            guard score >= 20 else {
                continue
            }

            let candidate = TransactionalImageCandidate(url: safeURL, style: style, score: score)
            if bestCandidate == nil || score > (bestCandidate?.score ?? Int.min) {
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    private func safeImageURL(from rawURL: String, descriptor: String, width: Int?, height: Int?) -> String? {
        let normalizedURL = normalizedText(rawURL)
        let lowercasedURL = normalizedURL.lowercased()

        guard isRenderableRemoteImageURL(normalizedURL),
              urlSanitizer.isURLSafe(normalizedURL),
              !trackingRemover.isTrackingLikeImageURL(normalizedURL),
              !transactionalPromotionalPatterns.contains(where: descriptor.contains),
              !transactionalPromotionalPatterns.contains(where: lowercasedURL.contains),
              !blockedTransactionalImageHints.contains(where: descriptor.contains),
              !blockedTransactionalImageHints.contains(where: lowercasedURL.contains) else {
            return nil
        }

        if let width, let height, (width <= 8 || height <= 8) {
            return nil
        }

        return normalizedURL
    }

    private func firstAmount(in text: String?) -> String? {
        guard let text = text, !text.isEmpty else {
            return nil
        }

        let pattern = #"([$€£])\s*([0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:[.\s]?([0-9]{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3,
              let symbolRange = Range(match.range(at: 1), in: text),
              let dollarsRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let symbol = String(text[symbolRange])
        let dollars = String(text[dollarsRange])
        let cents: String
        if match.numberOfRanges > 3,
           let centsRange = Range(match.range(at: 3), in: text),
           !centsRange.isEmpty {
            cents = String(text[centsRange])
        } else {
            cents = ""
        }

        guard !dollars.isEmpty else {
            return nil
        }

        if cents.isEmpty {
            return "\(symbol)\(dollars)"
        }

        return "\(symbol)\(dollars).\(cents)"
    }

    private func sanitizedTransactionTitle(_ text: String?) -> String? {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else {
            return nil
        }

        let withoutAmount = normalized.replacingOccurrences(
            of: #"\s*(?:[-–|:]\s*)?(?:[$€£]\s*[0-9]{1,3}(?:,[0-9]{3})*|[$€£]\s*[0-9]+)(?:[.\s]?[0-9]{2})?\s*$"#,
            with: "",
            options: [.regularExpression]
        )

        let trimmed = withoutAmount
            .replacingOccurrences(of: #"[\s\-–|:]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isMeaningfulTitle(trimmed) else {
            return nil
        }

        return trimmed
    }

    private func normalizedCandidateLine(_ text: String?) -> String? {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty,
              !shouldSkipLine(normalized),
              !shouldStopAtFooter(normalized) else {
            return nil
        }

        return normalized
    }

    private func normalizedStatus(_ text: String?) -> String? {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else {
            return nil
        }

        let wordCount = normalized.split(whereSeparator: \.isWhitespace).count
        guard wordCount <= 3 else {
            return nil
        }

        let lowercased = normalized.lowercased()
        guard let matchedStatus = transactionalStatusPatterns.first(where: { lowercased.contains($0) }) else {
            return nil
        }

        return matchedStatus
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func looksLikeDateOrStatus(_ text: String) -> Bool {
        normalizedStatus(text) != nil || looksLikeDate(text)
    }

    private func looksLikeDate(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if months.contains(where: lowercased.contains) {
            return true
        }

        return lowercased.range(of: #"^\d{1,2}/\d{1,2}/\d{2,4}$"#, options: .regularExpression) != nil
    }

    private func resolvedReservationDetailLine(from lines: [String]) -> String? {
        let combinedText = lines.joined(separator: "\n").lowercased()
        guard combinedText.contains("reservation") else {
            return nil
        }

        var dateLine: String?
        var dateLineIndex: Int?
        var partyLine: String?
        var partyLineIndex: Int?

        for (index, line) in lines.enumerated() {
            let normalized = normalizedText(line)
            guard !normalized.isEmpty else {
                continue
            }

            if dateLine == nil, looksLikeDate(normalized) {
                dateLine = normalized
                dateLineIndex = index
            }

            if partyLine == nil, let candidate = reservationPartySize(in: normalized) {
                partyLine = candidate
                partyLineIndex = index
            }
        }

        var timeLine: String?
        for (index, line) in lines.enumerated() {
            let normalized = normalizedText(line)
            guard !normalized.isEmpty else {
                continue
            }

            if timeLine == nil,
               let candidate = reservationTime(in: normalized),
               isReservationTimeLine(
                index: index,
                line: normalized,
                dateLineIndex: dateLineIndex,
                partyLineIndex: partyLineIndex
               ) {
                timeLine = candidate
            }
        }

        let segments = [dateLine, partyLine, timeLine].compactMap { $0 }
        guard !segments.isEmpty else {
            return nil
        }

        return truncate(segments.joined(separator: " • "), limit: 90)
    }

    private func resolvedReservationSubtitle(from lines: [String], excluding excludedValues: Set<String>) -> String? {
        for line in lines {
            guard let candidate = normalizedCandidateLine(line) else {
                continue
            }

            let comparable = normalizedComparableText(candidate)
            let isReservationCancellation =
                comparable.contains("reservation has been cancelled") ||
                comparable.contains("reservation has been canceled")
            guard !excludedValues.contains(comparable),
                  isReservationCancellation else {
                continue
            }

            return truncate(candidate, limit: 90)
        }

        return nil
    }

    private func reservationPartySize(in line: String) -> String? {
        guard let range = line.range(
            of: #"\b\d+\s+(?:guest|guests|person|people)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        return normalizedReservationPartyTimeLine(String(line[range]))
    }

    private func isReservationTimeLine(index: Int, line: String, dateLineIndex: Int?, partyLineIndex: Int?) -> Bool {
        if index == dateLineIndex || index == partyLineIndex {
            return true
        }

        guard isStandaloneReservationTime(line) || isLabelledReservationTime(line) else {
            return false
        }

        return [dateLineIndex, partyLineIndex]
            .compactMap { $0 }
            .contains { abs($0 - index) == 1 }
    }

    private func isStandaloneReservationTime(_ line: String) -> Bool {
        line.range(
            of: #"^\d{1,2}:\d{2}\s*(?:AM|PM)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isLabelledReservationTime(_ line: String) -> Bool {
        line.range(
            of: #"^(?:reservation\s+)?time(?:\s*:\s*|\s+)\d{1,2}:\d{2}\s*(?:AM|PM)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func reservationTime(in line: String) -> String? {
        guard let range = line.range(
            of: #"\b\d{1,2}:\d{2}\s*(?:AM|PM)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        return normalizedReservationPartyTimeLine(String(line[range]))
    }

    private func normalizedReservationPartyTimeLine(_ line: String) -> String {
        normalizedText(line)
            .replacingOccurrences(of: "⋅", with: " • ")
            .replacingOccurrences(of: "·", with: " • ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func isDetailFieldLabel(_ text: String) -> Bool {
        canonicalDetailField(for: text) != nil || normalizedComparableText(text) == "transaction details"
    }

    private func containsLetter(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .letters) != nil
    }

    private func normalizedSourceDomain(from senderEmail: String?) -> String? {
        guard let senderEmail = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !senderEmail.isEmpty else {
            return nil
        }

        let extractedEmail = EmailNormalizer.extractEmail(from: senderEmail) ?? senderEmail
        guard let atIndex = extractedEmail.lastIndex(of: "@"),
              atIndex < extractedEmail.index(before: extractedEmail.endIndex) else {
            return nil
        }

        let domain = extractedEmail[extractedEmail.index(after: atIndex)...]
            .lowercased()
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'()[],:;"))

        return domain.isEmpty ? nil : domain
    }

    private func sourceLabel(senderName: String?, sourceDomain: String?) -> String? {
        let normalizedSenderName = normalizedText(senderName)
        if !normalizedSenderName.isEmpty, !normalizedSenderName.contains("@") {
            return truncate(normalizedSenderName, limit: 40)
        }

        guard let sourceDomain, !sourceDomain.isEmpty else {
            return nil
        }

        let primarySegment = sourceDomain
            .split(separator: ".")
            .map(String.init)
            .first(where: { segment in
                let lowercased = segment.lowercased()
                return lowercased.count > 1 && !ignoredSourceSubdomains.contains(lowercased)
            })?
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let primarySegment, !primarySegment.isEmpty else {
            return nil
        }

        return primarySegment.capitalized
    }

    private func normalizedSet(from strings: [String?]) -> Set<String> {
        Set(strings.compactMap { value in
            let normalized = normalizedComparableText(value)
            return normalized.isEmpty ? nil : normalized
        })
    }

    private func restatesExcludedContent(_ text: String, excluded: [String?]) -> Bool {
        var remainder = normalizedComparableText(text)
        guard !remainder.isEmpty else {
            return false
        }

        let excludedValues = normalizedSet(from: excluded)
            .sorted { $0.count > $1.count }
        var removedAny = false

        for excludedValue in excludedValues where remainder.contains(excludedValue) {
            remainder = remainder.replacingOccurrences(of: excludedValue, with: " ")
            removedAny = true
        }

        guard removedAny else {
            return false
        }

        remainder = remainder
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return remainder.isEmpty
    }

    private func normalizedComparableText(_ text: String?) -> String {
        normalizedText(text).lowercased()
    }

    private func normalizedText(_ text: String?) -> String {
        EmailPreviewContentExtractor.normalizedText(text)
    }

    private func normalizedPreviewText(_ text: String?) -> String? {
        let normalized = normalizedText(text)
        return normalized.isEmpty ? nil : normalized
    }

    private func shouldSkipLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if line.count < 2 {
            return true
        }

        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return true
        }

        if lowercased.contains("{") && lowercased.contains("}") && lowercased.contains(":") {
            return true
        }

        if line.range(of: #"^[\d\W]{1,6}$"#, options: .regularExpression) != nil {
            return true
        }

        if line.range(of: #"^:[a-z0-9_+\-]+:$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }

        if lowercased.hasSuffix(" logo") || lowercased == "venmo" {
            return true
        }

        if looksLikeStandaloneActionLabel(lowercased) {
            return true
        }

        if promotionalTransactionLineHints.contains(where: lowercased.contains) {
            return true
        }

        return false
    }

    private func looksLikeStandaloneActionLabel(_ text: String) -> Bool {
        let normalized = normalizedText(text).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        let wordCount = normalized.split(whereSeparator: \.isWhitespace).count
        guard wordCount <= 4 else {
            return false
        }

        return preferredActionPatterns.contains(where: { pattern in
            normalized == pattern || normalized.hasPrefix(pattern + " ")
        })
    }

    private func shouldStopAtFooter(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return transactionalFooterStopPatterns.contains { lowercased.contains($0) }
    }

    private func isMeaningfulTitle(_ title: String) -> Bool {
        let normalized = normalizedText(title)
        guard normalized.count >= 8,
              normalized.count <= 90 else {
            return false
        }

        let lowercased = normalized.lowercased()
        guard !shouldSkipLine(normalized),
              !shouldStopAtFooter(normalized),
              !isDetailFieldLabel(normalized),
              !genericTransactionTitleValues.contains(lowercased),
              !ignoredTitlePatterns.contains(where: lowercased.contains) else {
            return false
        }

        return true
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let truncated = String(text.prefix(limit))
        if let lastSpace = truncated.lastIndex(of: " "),
           truncated.distance(from: truncated.startIndex, to: lastSpace) > limit - 20 {
            return String(truncated[..<lastSpace]) + "..."
        }

        return truncated + "..."
    }

    private func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let width, let height, width > 0, height > 0 else {
            return nil
        }

        return Double(width) / Double(height)
    }

    private func isRenderableRemoteImageURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !lowercased.isEmpty,
              !lowercased.hasPrefix("cid:"),
              !lowercased.hasPrefix("data:"),
              !lowercased.contains("about:blank"),
              let parsedURL = URL(string: trimmed),
              let scheme = parsedURL.scheme?.lowercased(),
              let host = parsedURL.host,
              !host.isEmpty else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }
}

private struct TransactionalImageCandidate {
    let url: String
    let style: TransactionalPreviewImageStyle
    let score: Int
}

private let transactionalTitlePatterns = [
    "you paid",
    "paid you",
    "money credited",
    "credited to your",
    "payment received",
    "payment sent",
    "payment completed",
    "transfer completed",
    "transfer confirmation",
    "deposit completed",
    "deposit confirmation",
    "deposit declined",
    "order confirmed",
    "order confirmation",
    "reservation confirmation",
    "reservation cancellation",
    "reservation has been canceled",
    "reservation has been cancelled",
    "reservation canceled",
    "reservation cancelled",
    "security alert",
    "security notice",
    "receipt",
    "statement ready",
    "review activity"
]

private let preferredActionPatterns = [
    "see transaction",
    "view receipt",
    "view order",
    "track package",
    "review activity",
    "view details",
    "see details",
    "manage order",
    "view statement"
]

private let ignoredActionPatterns = [
    "sign up",
    "debit card",
    "learn more",
    "help center",
    "privacy policy",
    "disclosures",
    "licenses",
    "unsubscribe",
    "contact us"
]

private let blockedTransactionalImageHints = [
    "logo",
    "wordmark",
    "banner",
    "cashback",
    "debit",
    "promo",
    "offer",
    "reward",
    "hero"
]

private let promotionalTransactionLineHints = [
    "earn up to",
    "cashback",
    "sign up for the debit card",
    "spend your venmo balance",
    "earn rewards",
    "buy now, pay later",
    "shop now",
    "debit card"
]

private let transactionalPromotionalPatterns = promotionalTransactionLineHints + blockedTransactionalImageHints

private let transactionalFooterStopPatterns = [
    "for any issues",
    "experience by",
    "you are receiving this email",
    "help center",
    "customer support",
    "see our disclosures",
    "licensed provider",
    "for security reasons",
    "you cannot unsubscribe",
    "paypal is located",
    "privacy policy",
    "terms and conditions",
    "venmo rt",
    "all money transmission"
]

private let ignoredTitlePatterns = [
    "help center",
    "privacy policy",
    "disclosures",
    "licenses",
    "venmo rt"
]

private let genericTransactionTitleValues: Set<String> = [
    "payment complete"
]

private let detailFieldPatterns: [String: [String]] = [
    "status": ["status"],
    "date": ["date", "processed on", "payment date", "posted"],
    "paymentMethod": ["payment method", "paid with", "payment source", "payment from"],
    "transactionID": ["transaction id", "confirmation number", "receipt number", "reference number", "order number"],
    "sentFrom": ["sent from", "from account"],
    "merchant": ["merchant", "recipient", "seller"]
]

private let transactionalStatusPatterns = [
    "pending",
    "completed",
    "complete",
    "paid",
    "credited",
    "processing",
    "shipped",
    "delivered",
    "failed",
    "canceled",
    "cancelled",
    "refunded",
    "declined"
]

private let months = [
    "jan", "feb", "mar", "apr", "may", "jun",
    "jul", "aug", "sep", "oct", "nov", "dec"
]

private let ignoredSourceSubdomains = [
    "www",
    "m",
    "mail",
    "email",
    "notifications",
    "updates"
]
