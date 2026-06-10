import Foundation

/// Preview metadata matched from an Apple developer notification email
/// (App Store Connect build processing, or TestFlight availability).
struct AppleDeveloperNotification {
    let title: String?
    let metadataLine: String?
    let status: String?
    let sourceLabel: String
    let suppressesAmountExtraction: Bool
}

/// Detects Apple developer notification emails and extracts their preview
/// metadata (App Store Connect build-processing updates and TestFlight build
/// availability).
///
/// Extracted from `TransactionalPreviewBuilder` so the Apple-specific detection
/// and parsing rules live in one focused, independently testable unit. The
/// shared text helpers it still relies on — line truncation and the builder's
/// `sanitizeTitle` / `normalizeLine` normalizers — are injected so the extractor
/// stays free of the builder's broader state.
struct AppStoreNotificationPreviewExtractor {
    private let lineProcessor: PreviewLineProcessor
    private let sanitizeTitle: (String?) -> String?
    private let normalizeLine: (String?) -> String?

    init(
        lineProcessor: PreviewLineProcessor,
        sanitizeTitle: @escaping (String?) -> String?,
        normalizeLine: @escaping (String?) -> String?
    ) {
        self.lineProcessor = lineProcessor
        self.sanitizeTitle = sanitizeTitle
        self.normalizeLine = normalizeLine
    }

    /// Apple sends these notifications from subdomains like `email.apple.com` and
    /// `appstoreconnect.apple.com`; anchoring on the `apple.com` domain suffix
    /// covers them without accepting spoofed lookalike senders.
    static let appleSenderDomainSuffixes: Set<String> = ["apple.com"]

    static func isAppleDeveloperSender(senderEmail: String?, sourceDomain: String?) -> Bool {
        PreviewTextUtilities.domain(sourceDomain, matchesDomainOrSuffixIn: appleSenderDomainSuffixes) ||
            PreviewTextUtilities.senderDomain(senderEmail, matchesDomainOrSuffixIn: appleSenderDomainSuffixes)
    }

    /// Returns an Apple developer notification preview when the email matches an
    /// App Store Connect build-processing or TestFlight availability message,
    /// otherwise `nil`.
    func notification(
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

        let isAppleSender = Self.isAppleDeveloperSender(senderEmail: senderEmail, sourceDomain: sourceDomain)
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
        let title = sanitizeTitle(normalizedSubject)
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

        let isAppleSender = Self.isAppleDeveloperSender(senderEmail: senderEmail, sourceDomain: sourceDomain)
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
        let title = sanitizeTitle(normalizedSubject)
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
                for: ["Version Number", "Bundle Version Short String", "Version"],
                in: lines
            )
        )
    }

    private func appStoreBuildNumber(subject: String, lines: [String]) -> String? {
        if let buildNumber = firstRegexCapture(in: subject, pattern: #"\bversion\s+[A-Za-z0-9][A-Za-z0-9._-]*\s*\(([^)]+)\)"#) {
            return buildNumber
        }

        return normalizedAppStoreBuildNumber(appStoreValue(for: ["Build Number", "Bundle Version", "Build"], in: lines))
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
        if containsPositiveAppStoreBetaApproval(in: text) {
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

    private func containsPositiveAppStoreBetaApproval(in text: String) -> Bool {
        guard !containsNegatedAppStoreBetaApproval(in: text) else {
            return false
        }

        return text.contains("approved for beta testing") ||
            text.contains("approved for testflight beta testing")
    }

    private func containsNegatedAppStoreBetaApproval(in text: String) -> Bool {
        let patterns = [
            #"\bnot\s+(?:yet\s+)?(?:been\s+)?approved\s+for\s+(?:testflight\s+)?beta\s+testing\b"#,
            #"\b(?:isn['’]?t|wasn['’]?t|hasn['’]?t|haven['’]?t)\s+(?:been\s+)?approved\s+for\s+(?:testflight\s+)?beta\s+testing\b"#
        ]

        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
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
                          let normalized = normalizeLine(candidate) else {
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
}

private struct TestFlightBuildInfo {
    let appName: String?
    let version: String?
    let buildNumber: String?
    let platform: String?
}
