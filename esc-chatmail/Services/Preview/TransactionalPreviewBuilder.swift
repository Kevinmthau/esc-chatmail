import Foundation

struct TransactionalPreviewBuilder {
    private let imageExtractor = EmailPreviewImageExtractor()
    private let urlSanitizer = HTMLURLSanitizer()
    private let trackingRemover = HTMLTrackingRemover()
    private let lineProcessor = PreviewLineProcessor(
        config: PreviewLineProcessorConfig(
            footerStopPatterns: transactionalFooterStopPatterns,
            truncationTrailingMinDistance: 20
        )
    )

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
        let sourceDomain = PreviewTextUtilities.normalizedSourceDomain(from: senderEmail)
        let inferredSourceLabel = sourceLabel(
            senderName: senderName,
            senderEmail: senderEmail,
            sourceDomain: sourceDomain
        )
        let lines = cleanedPreviewLines(
            plainText: plainText,
            canonicalHTML: canonicalHTML,
            extractedText: extractedText
        )
        let appleDeveloperNotification = appleDeveloperNotification(
            canonicalHTML: canonicalHTML,
            subject: subject,
            senderEmail: senderEmail,
            sourceDomain: sourceDomain,
            lines: lines
        )
        let sourceLabel = appleDeveloperNotification?.sourceLabel ?? inferredSourceLabel
        let detailFields = detailFields(from: lines)
        let title = appleDeveloperNotification?.title ?? resolvedTitle(
            from: htmlSummary,
            subject: subject,
            lines: lines,
            sourceLabel: sourceLabel
        )
        let amount = appleDeveloperNotification?.suppressesAmountExtraction == true
            ? nil
            : resolvedAmount(
                subject: subject,
                cleanedSnippet: cleanedSnippet,
                lines: lines,
                extractedText: extractedText
            )
        let subtitle = appleDeveloperNotification?.metadataLine ?? resolvedSubtitle(
            cleanedSnippet: cleanedSnippet,
            from: lines,
            excluding: [title, amount, sourceLabel, sourceDomain]
        )
        let status = appleDeveloperNotification?.status ?? resolvedStatus(from: detailFields, lines: lines, excluding: [title, subtitle])
        let detailLine = appleDeveloperNotification == nil
            ? resolvedDetailLine(
                from: detailFields,
                lines: lines,
                status: status,
                excluding: [title, subtitle, amount, sourceLabel, sourceDomain]
            )
            : nil
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
            return lineProcessor.truncate(candidate, limit: 90)
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
            PreviewTextUtilities.normalizedPreviewText(extractedText)
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
        let excludedValues = PreviewTextUtilities.normalizedSet(from: excluded)

        if let cleanedSnippet = normalizedCandidateLine(cleanedSnippet),
           !excludedValues.contains(PreviewTextUtilities.normalizedComparableText(cleanedSnippet)),
           !restatesExcludedContent(cleanedSnippet, excluded: excluded),
           cleanedSnippet.count >= 14 {
            return lineProcessor.truncate(cleanedSnippet, limit: 90)
        }

        if let reservationSubtitle = resolvedReservationSubtitle(from: lines, excluding: excludedValues) {
            return reservationSubtitle
        }

        for line in lines {
            guard let candidate = normalizedCandidateLine(line) else {
                continue
            }

            let comparable = PreviewTextUtilities.normalizedComparableText(candidate)
            guard !excludedValues.contains(comparable),
                  !restatesExcludedContent(candidate, excluded: excluded),
                  candidate.count >= 14,
                  candidate.count <= 90,
                  !looksLikeDateOrStatus(candidate),
                  !isDetailFieldLabel(candidate),
                  containsLetter(candidate) else {
                continue
            }

            return lineProcessor.truncate(candidate, limit: 90)
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

        let excludedValues = PreviewTextUtilities.normalizedSet(from: excluded)
        for line in lines {
            let comparable = PreviewTextUtilities.normalizedComparableText(line)
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
            return lineProcessor.truncate(segments.prefix(2).joined(separator: " • "), limit: 90)
        }

        if let reservationDetailLine = resolvedReservationDetailLine(from: lines) {
            return reservationDetailLine
        }

        let excludedValues = PreviewTextUtilities.normalizedSet(from: excluded + [status])
        for line in lines {
            guard let candidate = normalizedCandidateLine(line) else {
                continue
            }

            let comparable = PreviewTextUtilities.normalizedComparableText(candidate)
            guard !excludedValues.contains(comparable),
                  !restatesExcludedContent(candidate, excluded: excluded + [status]),
                  !looksLikeDateOrStatus(candidate),
                  !isDetailFieldLabel(candidate),
                  candidate.count >= 10,
                  containsLetter(candidate) else {
                continue
            }

            return lineProcessor.truncate(candidate, limit: 90)
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
                return lineProcessor.truncate(candidate, limit: 32)
            }

        }

        return nil
    }

    private func appleDeveloperNotification(
        canonicalHTML: String,
        subject: String?,
        senderEmail: String?,
        sourceDomain: String?,
        lines: [String]
    ) -> AppleDeveloperNotification? {
        appStoreConnectBuildNotification(
            canonicalHTML: canonicalHTML,
            subject: subject,
            senderEmail: senderEmail,
            sourceDomain: sourceDomain,
            lines: lines
        ) ?? testFlightAvailabilityNotification(
            canonicalHTML: canonicalHTML,
            subject: subject,
            senderEmail: senderEmail,
            sourceDomain: sourceDomain,
            lines: lines
        )
    }

    private func appStoreConnectBuildNotification(
        canonicalHTML: String,
        subject: String?,
        senderEmail: String?,
        sourceDomain: String?,
        lines: [String]
    ) -> AppleDeveloperNotification? {
        let normalizedSubject = PreviewTextUtilities.normalizedText(subject)
        let lineText = lines.joined(separator: "\n")
        let lowercasedText = [normalizedSubject, lineText]
            .joined(separator: "\n")
            .lowercased()
        let lowercasedHTML = canonicalHTML.lowercased()
        let lowercasedSender = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let lowercasedDomain = sourceDomain?.lowercased() ?? ""

        let isAppleSender =
            lowercasedDomain == "email.apple.com" ||
            lowercasedDomain == "appstoreconnect.apple.com" ||
            lowercasedDomain.hasSuffix(".apple.com") ||
            lowercasedSender.contains("@email.apple.com") ||
            lowercasedSender.contains("@appstoreconnect.apple.com")
        let mentionsAppStoreConnect =
            lowercasedText.contains("app store connect") ||
            lowercasedHTML.contains("app store connect")
        let hasBuildLifecycleSignal =
            lowercasedText.contains("has completed processing") ||
            lowercasedHTML.contains("has completed processing") ||
            lowercasedText.contains("build has completed processing") ||
            lowercasedHTML.contains("build has completed processing") ||
            lowercasedText.contains("approved for beta testing") ||
            lowercasedHTML.contains("approved for beta testing") ||
            lowercasedText.contains("approved for testflight beta testing") ||
            lowercasedHTML.contains("approved for testflight beta testing") ||
            (lowercasedText.contains("version number") && lowercasedText.contains("build number")) ||
            (lowercasedHTML.contains("version number") && lowercasedHTML.contains("build number"))

        guard isAppleSender, mentionsAppStoreConnect, hasBuildLifecycleSignal else {
            return nil
        }

        let appName = appStoreAppName(subject: normalizedSubject, lines: lines)
        let version = appStoreVersion(subject: normalizedSubject, lines: lines)
        let buildNumber = appStoreBuildNumber(subject: normalizedSubject, lines: lines)
        let metadataSegments = [
            appName,
            version.map { "Version \($0)" },
            buildNumber.map { "Build \($0)" }
        ].compactMap { $0 }
        let metadataLine = metadataSegments.isEmpty
            ? nil
            : lineProcessor.truncate(metadataSegments.joined(separator: " • "), limit: 90)
        let title = sanitizedTransactionTitle(normalizedSubject)
            ?? (!normalizedSubject.isEmpty ? lineProcessor.truncate(normalizedSubject, limit: 90) : nil)

        return AppleDeveloperNotification(
            title: title,
            metadataLine: metadataLine,
            status: appStoreProcessingStatus(from: lowercasedText + "\n" + lowercasedHTML),
            sourceLabel: "App Store Connect",
            suppressesAmountExtraction: false
        )
    }

    private func testFlightAvailabilityNotification(
        canonicalHTML: String,
        subject: String?,
        senderEmail: String?,
        sourceDomain: String?,
        lines: [String]
    ) -> AppleDeveloperNotification? {
        let normalizedSubject = PreviewTextUtilities.normalizedText(subject)
        let lineText = lines.joined(separator: "\n")
        let lowercasedText = [normalizedSubject, lineText]
            .joined(separator: "\n")
            .lowercased()
        let lowercasedHTML = canonicalHTML.lowercased()
        let lowercasedSender = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let lowercasedDomain = sourceDomain?.lowercased() ?? ""

        let isAppleSender =
            lowercasedDomain == "email.apple.com" ||
            lowercasedDomain == "appstoreconnect.apple.com" ||
            lowercasedDomain.hasSuffix(".apple.com") ||
            lowercasedSender.contains("@email.apple.com") ||
            lowercasedSender.contains("@appstoreconnect.apple.com")
        let mentionsTestFlight =
            lowercasedSender.contains("testflight") ||
            lowercasedText.contains("testflight") ||
            lowercasedHTML.contains("testflight")
        let hasAvailabilitySignal =
            lowercasedText.contains("is now available to test") ||
            lowercasedHTML.contains("is now available to test") ||
            lowercasedText.contains("is ready to test") ||
            lowercasedHTML.contains("is ready to test")

        guard isAppleSender, mentionsTestFlight, hasAvailabilitySignal else {
            return nil
        }

        let buildInfo = testFlightBuildInfo(subject: normalizedSubject, lines: lines)
        let appName = buildInfo?.appName
        let version = buildInfo?.version
        let buildNumber = buildInfo?.buildNumber
        let platform = buildInfo?.platform
        let metadataSegments = [
            appName,
            version.map { "Version \($0)" },
            buildNumber.map { "Build \($0)" },
            platform
        ].compactMap { $0 }
        let metadataLine = metadataSegments.isEmpty
            ? nil
            : lineProcessor.truncate(metadataSegments.joined(separator: " • "), limit: 90)
        let title = sanitizedTransactionTitle(normalizedSubject)
            ?? (!normalizedSubject.isEmpty ? lineProcessor.truncate(normalizedSubject, limit: 90) : nil)

        return AppleDeveloperNotification(
            title: title,
            metadataLine: metadataLine,
            status: "Ready",
            sourceLabel: "TestFlight",
            suppressesAmountExtraction: true
        )
    }

    private func appStoreAppName(subject: String, lines: [String]) -> String? {
        firstRegexCapture(
            in: subject,
            pattern: #"\bfor\s+(.+?)\s+has\s+completed\s+processing\b"#
        ) ?? appStoreValue(for: ["App Name", "App"], in: lines)
    }

    private func appStoreVersion(subject: String, lines: [String]) -> String? {
        if let version = firstRegexCapture(
            in: subject,
            pattern: #"\bversion\s+([A-Za-z0-9][A-Za-z0-9._-]*)"#
        ) {
            return version
        }

        return normalizedAppStoreVersion(
            appStoreValue(
                for: ["Version Number", "Bundle Version Short String", "Bundle Version", "Version"],
                in: lines
            )
        )
    }

    private func appStoreBuildNumber(subject: String, lines: [String]) -> String? {
        if let buildNumber = firstRegexCapture(in: subject, pattern: #"\bversion\s+[A-Za-z0-9][A-Za-z0-9._-]*\s*\(([^)]+)\)"#) {
            return buildNumber
        }

        return normalizedAppStoreBuildNumber(appStoreValue(for: ["Build Number", "Build"], in: lines))
    }

    private func testFlightBuildInfo(subject: String, lines: [String]) -> TestFlightBuildInfo? {
        let candidates = [subject] + lines
        for candidate in candidates {
            let normalized = PreviewTextUtilities.normalizedText(candidate)
            guard !normalized.isEmpty else {
                continue
            }

            if let captures = firstRegexCaptures(
                in: normalized,
                pattern: #"^(.+?)\s+([A-Za-z0-9][A-Za-z0-9._-]*)\s*\(([^)]+)\)\s+for\s+(.+?)\s+is\s+now\s+available\s+to\s+test\.?$"#
            ), captures.count == 4 {
                return TestFlightBuildInfo(
                    appName: captures[0],
                    version: captures[1],
                    buildNumber: captures[2],
                    platform: captures[3]
                )
            }

            if let captures = firstRegexCaptures(
                in: normalized,
                pattern: #"^(.+?)\s+([A-Za-z0-9][A-Za-z0-9._-]*)\s*\(([^)]+)\)\s+is\s+ready\s+to\s+test\s+on\s+(.+?)\.?$"#
            ), captures.count == 4 {
                return TestFlightBuildInfo(
                    appName: captures[0],
                    version: captures[1],
                    buildNumber: captures[2],
                    platform: captures[3]
                )
            }
        }

        return nil
    }

    private func appStoreProcessingStatus(from text: String) -> String? {
        if text.contains("approved for beta testing") ||
            text.contains("approved for testflight beta testing") {
            return "Approved"
        }

        if text.contains("has completed processing") || text.contains("completed processing") {
            return "Completed"
        }

        if text.contains("failed processing") || text.contains("processing failed") {
            return "Failed"
        }

        if text.contains("is processing") || text.contains("started processing") {
            return "Processing"
        }

        return nil
    }

    private func appStoreValue(for labels: [String], in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            for label in labels {
                if let inlineValue = appStoreInlineValue(for: label, in: line) {
                    return inlineValue
                }

                guard PreviewTextUtilities.normalizedComparableText(line) == PreviewTextUtilities.normalizedComparableText(label) else {
                    continue
                }

                for nextIndex in lines.index(after: index)..<min(lines.count, index + 4) {
                    let candidate = lines[nextIndex]
                    guard !isAppStoreMetadataLabel(candidate),
                          let normalized = normalizedCandidateLine(candidate) else {
                        continue
                    }

                    return normalized
                }
            }
        }

        return nil
    }

    private func appStoreInlineValue(for label: String, in line: String) -> String? {
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: label) + #"\s*[:\-]\s*(.+)$"#
        return firstRegexCapture(in: line, pattern: pattern)
    }

    private func normalizedAppStoreVersion(_ text: String?) -> String? {
        guard let value = PreviewTextUtilities.normalizedText(text).split(separator: " ").first else {
            return nil
        }

        let normalized = String(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedAppStoreBuildNumber(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let normalized = PreviewTextUtilities.normalizedText(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        return normalized.isEmpty ? nil : normalized
    }

    private func isAppStoreMetadataLabel(_ text: String) -> Bool {
        let comparable = PreviewTextUtilities.normalizedComparableText(text)
        return [
            "app",
            "app name",
            "version",
            "version number",
            "bundle version",
            "bundle version short string",
            "build",
            "build number"
        ].contains(comparable)
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        firstRegexCaptures(in: text, pattern: pattern)?.first
    }

    private func firstRegexCaptures(in text: String, pattern: String) -> [String]? {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else {
            return nil
        }

        let captures = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard let captureRange = Range(match.range(at: index), in: text) else {
                return nil
            }
            let capture = PreviewTextUtilities.normalizedText(String(text[captureRange]))
            return capture.isEmpty ? nil : capture
        }
        return captures.isEmpty ? nil : captures
    }

    private func cleanedPreviewLines(
        plainText: String?,
        canonicalHTML: String,
        extractedText: String? = nil
    ) -> [String] {
        let bodyLines = previewLines(from: plainText ?? "")
        let htmlText = PreviewTextUtilities.normalizedPreviewText(extractedText)
            ?? PreviewTextUtilities.normalizedText(TextProcessing.extractPlainText(from: canonicalHTML))
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
            let normalizedLine = PreviewTextUtilities.normalizedText(line)
            guard !normalizedLine.isEmpty else {
                continue
            }

            if lineProcessor.shouldStopAtFooter(normalizedLine), !lines.isEmpty {
                break
            }

            if shouldSkipLine(normalizedLine) {
                continue
            }

            let comparable = PreviewTextUtilities.normalizedComparableText(normalizedLine)
            if lines.contains(where: { PreviewTextUtilities.normalizedComparableText($0) == comparable }) {
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
        let lowercased = PreviewTextUtilities.normalizedComparableText(label)

        for (key, patterns) in detailFieldPatterns {
            if patterns.contains(where: lowercased.contains) {
                return key
            }
        }

        return nil
    }

    private func transactionLine(from lines: [String], excluding excluded: [String?]) -> String? {
        let excludedValues = PreviewTextUtilities.normalizedSet(from: excluded)

        for line in lines {
            let comparable = PreviewTextUtilities.normalizedComparableText(line)
            guard !excludedValues.contains(comparable),
                  looksLikeTransactionalTitle(line) else {
                continue
            }

            return line
        }

        return nil
    }

    private func looksLikeTransactionalTitle(_ line: String) -> Bool {
        let lowercased = PreviewTextUtilities.normalizedComparableText(line)

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
            let aspectRatio = PreviewTextUtilities.aspectRatio(width: width, height: height)
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
        let normalizedURL = PreviewTextUtilities.normalizedText(rawURL)
        let lowercasedURL = normalizedURL.lowercased()

        guard PreviewTextUtilities.isRenderableRemoteImageURL(normalizedURL),
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

        return EmailPreviewRemoteImageURL.normalizedForNativePreview(normalizedURL)
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
        let normalized = PreviewTextUtilities.normalizedText(text)
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
        let normalized = PreviewTextUtilities.normalizedText(text)
        guard !normalized.isEmpty,
              !shouldSkipLine(normalized),
              !lineProcessor.shouldStopAtFooter(normalized) else {
            return nil
        }

        return normalized
    }

    private func normalizedStatus(_ text: String?) -> String? {
        let normalized = PreviewTextUtilities.normalizedText(text)
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
            let normalized = PreviewTextUtilities.normalizedText(line)
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
            let normalized = PreviewTextUtilities.normalizedText(line)
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

        return lineProcessor.truncate(segments.joined(separator: " • "), limit: 90)
    }

    private func resolvedReservationSubtitle(from lines: [String], excluding excludedValues: Set<String>) -> String? {
        for line in lines {
            guard let candidate = normalizedCandidateLine(line) else {
                continue
            }

            let comparable = PreviewTextUtilities.normalizedComparableText(candidate)
            let isReservationCancellation =
                comparable.contains("reservation has been cancelled") ||
                comparable.contains("reservation has been canceled")
            guard !excludedValues.contains(comparable),
                  isReservationCancellation else {
                continue
            }

            return lineProcessor.truncate(candidate, limit: 90)
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
        PreviewTextUtilities.normalizedText(line)
            .replacingOccurrences(of: "⋅", with: " • ")
            .replacingOccurrences(of: "·", with: " • ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func isDetailFieldLabel(_ text: String) -> Bool {
        canonicalDetailField(for: text) != nil || PreviewTextUtilities.normalizedComparableText(text) == "transaction details"
    }

    private func containsLetter(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .letters) != nil
    }

    private func sourceLabel(senderName: String?, senderEmail: String?, sourceDomain: String?) -> String? {
        let normalizedSenderName: String
        if let senderEmail {
            normalizedSenderName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                senderName,
                forEmail: senderEmail
            ) ?? ""
        } else {
            normalizedSenderName = PreviewTextUtilities.normalizedText(senderName)
        }
        if !normalizedSenderName.isEmpty, !normalizedSenderName.contains("@") {
            return lineProcessor.truncate(normalizedSenderName, limit: 40)
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

    private func restatesExcludedContent(_ text: String, excluded: [String?]) -> Bool {
        var remainder = PreviewTextUtilities.normalizedComparableText(text)
        guard !remainder.isEmpty else {
            return false
        }

        let excludedValues = PreviewTextUtilities.normalizedSet(from: excluded)
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

    private func shouldSkipLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if line.count < 2 {
            return true
        }

        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return true
        }

        if looksLikeSalutationLine(line) {
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
        let normalized = PreviewTextUtilities.normalizedText(text).lowercased()
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

    private func isMeaningfulTitle(_ title: String) -> Bool {
        let normalized = PreviewTextUtilities.normalizedText(title)
        guard normalized.count >= 8,
              normalized.count <= 90 else {
            return false
        }

        let lowercased = normalized.lowercased()
        guard !shouldSkipLine(normalized),
              !lineProcessor.shouldStopAtFooter(normalized),
              !isDetailFieldLabel(normalized),
              !genericTransactionTitleValues.contains(lowercased),
              !ignoredTitlePatterns.contains(where: lowercased.contains) else {
            return false
        }

        return true
    }

    private func looksLikeSalutationLine(_ line: String) -> Bool {
        let normalized = PreviewTextUtilities.normalizedText(line)
        let wordCount = normalized.split(whereSeparator: \.isWhitespace).count
        guard wordCount <= 5 else {
            return false
        }

        return normalized.range(
            of: #"^(?:dear|hi|hello|hey)\s+[\p{L}\p{M}.' -]+,?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

}

private struct AppleDeveloperNotification {
    let title: String?
    let metadataLine: String?
    let status: String?
    let sourceLabel: String
    let suppressesAmountExtraction: Bool
}

private struct TestFlightBuildInfo {
    let appName: String?
    let version: String?
    let buildNumber: String?
    let platform: String?
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
    "has completed processing",
    "build has completed processing",
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
