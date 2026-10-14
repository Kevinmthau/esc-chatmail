import Foundation

/// Preview metadata matched from an Apple developer notification email
/// (App Store Connect build processing, TestFlight availability, or an Apple
/// Developer Program agreement notice).
struct AppleDeveloperNotification {
    let title: String?
    let metadataLine: String?
    let status: String?
    /// Link-text patterns the builder's action-label resolver should accept for
    /// this notification ahead of its generic transactional patterns; empty
    /// leaves the generic matching alone.
    let preferredActionPatterns: [String]
    let sourceLabel: String
    let suppressesAmountExtraction: Bool
}

/// Detects Apple developer notification emails and extracts their preview
/// metadata (App Store Connect build-processing updates, TestFlight build
/// availability, and Apple Developer Program agreement notices).
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
    /// App Store Connect build-processing, TestFlight availability, or Apple
    /// Developer Program agreement message, otherwise `nil`.
    func notification(
        canonicalHTML: String,
        subject: String?,
        senderName: String? = nil,
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
        ) ?? developerProgramAgreementNotification(
            canonicalHTML: canonicalHTML,
            subject: subject,
            senderName: senderName,
            senderEmail: senderEmail,
            sourceDomain: sourceDomain,
            lines: lines
        )
    }

    /// Apple Developer Program agreement notices ("Updated Apple Developer
    /// Program License Agreement Now Available", a Paid Applications Agreement
    /// update) are legal service messages, but they carry Apple's full
    /// marketing footer and almost no body text, so the preview classifier never
    /// scored them transactional and the chat showed the rendered-HTML
    /// snapshot: an Apple logo over a mostly blank card. The gate is anchored
    /// on the sender domain *and* the subject line, not the body: Apple's
    /// developer digests mention agreement updates as one story among many, and
    /// a body-only match would route those newsletters into the transactional
    /// card. Within the subject it also demands a *developer* agreement: either
    /// one of the known agreement names, or the singular word "agreement" next
    /// to a developer-program term in the subject or sender (`developer@`,
    /// an "App Store Connect" display name). Apple Card and Apple Business
    /// Manager send "agreement updated" mail from `apple.com` too, and without
    /// that term they were branded "Apple Developer". Replies and forwards are
    /// refused outright: a developer-support thread about the agreement is a
    /// conversation, not a notice.
    static func isDeveloperProgramAgreementNotice(
        senderName: String? = nil,
        senderEmail: String?,
        sourceDomain: String?,
        subject: String
    ) -> Bool {
        guard isAppleDeveloperSender(senderEmail: senderEmail, sourceDomain: sourceDomain) else {
            return false
        }

        let lowercasedSubject = PreviewTextUtilities.normalizedText(subject).lowercased()
        guard !lowercasedSubject.isEmpty,
              !Self.isReplyOrForwardSubject(lowercasedSubject),
              !developerDigestSubjectPatterns.contains(where: lowercasedSubject.contains),
              developerAgreementNoticeSubjectPatterns.contains(where: lowercasedSubject.contains) else {
            return false
        }

        if knownDeveloperAgreementName(in: lowercasedSubject) != nil {
            return true
        }

        // "agreements" (plural) is digest vocabulary ("Updated agreements and
        // guidelines now available"); a notice is about one agreement.
        guard lowercasedSubject.range(of: #"\bagreement\b"#, options: .regularExpression) != nil else {
            return false
        }

        let lowercasedSender = [senderName, senderEmail]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return developerProgramTerms.contains(where: lowercasedSubject.contains) ||
            developerProgramTerms.contains(where: lowercasedSender.contains)
    }

    private static func isReplyOrForwardSubject(_ lowercasedSubject: String) -> Bool {
        lowercasedSubject.range(of: #"^(?:re|fw|fwd)\s*:"#, options: .regularExpression) != nil
    }

    private static func knownDeveloperAgreementName(in lowercasedText: String) -> String? {
        knownDeveloperAgreementNames.first { lowercasedText.contains($0.lowercased()) }
    }

    private func developerProgramAgreementNotification(
        canonicalHTML: String,
        subject: String?,
        senderName: String?,
        senderEmail: String?,
        sourceDomain: String?,
        lines: [String]
    ) -> AppleDeveloperNotification? {
        let normalizedSubject = PreviewTextUtilities.normalizedText(subject)
        guard Self.isDeveloperProgramAgreementNotice(
            senderName: senderName,
            senderEmail: senderEmail,
            sourceDomain: sourceDomain,
            subject: normalizedSubject
        ) else {
            return nil
        }

        let lowercasedSubject = normalizedSubject.lowercased()
        let lowercasedBody = [lines.joined(separator: "\n"), canonicalHTML]
            .joined(separator: "\n")
            .lowercased()
        // The subject decides which agreement the notice is about. Apple's body
        // boilerplate cites other agreements ("as described in the Apple
        // Developer Program License Agreement") and a body-first scan named
        // that one on a Paid Applications notice.
        let subjectAgreementName = Self.knownDeveloperAgreementName(in: lowercasedSubject)
        let bodyAgreementName = subjectAgreementName == nil
            ? Self.knownDeveloperAgreementName(in: lowercasedBody)
            : nil
        let requiresAcceptance = Self.requiresAgreementAcceptance(
            in: lowercasedSubject + "\n" + lowercasedBody
        )

        // The subject usually names the agreement already; repeating it under the
        // title wastes the subtitle, so it carries the required action instead.
        let metadataLine: String?
        if let bodyAgreementName {
            metadataLine = bodyAgreementName
        } else if requiresAcceptance {
            metadataLine = lowercasedBody.contains("account holder")
                ? "Account Holder must review and accept"
                : "Review and accept the updated agreement"
        } else {
            metadataLine = nil
        }

        return AppleDeveloperNotification(
            title: subjectTitle(normalizedSubject),
            metadataLine: metadataLine,
            status: requiresAcceptance ? "Action Required" : "Updated",
            preferredActionPatterns: developerAgreementActionLinkPatterns,
            sourceLabel: "Apple Developer",
            suppressesAmountExtraction: true
        )
    }

    /// An acceptance phrase inside a negation ("you do not need to review and
    /// accept the updated agreement", "no action is required") is Apple telling
    /// the developer the opposite of "Action Required".
    private static func requiresAgreementAcceptance(in lowercasedText: String) -> Bool {
        guard developerAgreementAcceptancePatterns.contains(where: lowercasedText.contains) else {
            return false
        }

        return !developerAgreementNoActionPatterns.contains { pattern in
            lowercasedText.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// The card title every Apple notification shares: the sanitized subject,
    /// falling back to the subject itself when sanitizing rejects it.
    private func subjectTitle(_ normalizedSubject: String) -> String? {
        sanitizeTitle(normalizedSubject)
            ?? (normalizedSubject.isEmpty ? nil : lineProcessor.truncate(normalizedSubject, limit: 90))
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

        return AppleDeveloperNotification(
            title: subjectTitle(normalizedSubject),
            metadataLine: metadataLine,
            status: appStoreProcessingStatus(from: lowercasedText + "\n" + lowercasedHTML),
            preferredActionPatterns: [],
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

        return AppleDeveloperNotification(
            title: subjectTitle(normalizedSubject),
            metadataLine: metadataLine,
            status: "Ready",
            preferredActionPatterns: [],
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

/// Subject-line phrasing Apple uses for agreement notices; any one of these next
/// to "agreement" on an Apple sender marks the email as a program notice.
/// "update" also covers "updated".
private let developerAgreementNoticeSubjectPatterns = [
    "update",
    "now available",
    "review",
    "accept",
    "action required",
    "action needed",
    "reminder"
]

/// Subject vocabulary of Apple's developer digests and news mail, which cover
/// agreement updates as one story among several ("Updated agreements and
/// guidelines now available", "Hello Developer: ... and more").
private let developerDigestSubjectPatterns = [
    "hello developer",
    "and more",
    "guidelines",
    "wwdc",
    "edition",
    "digest",
    "newsletter",
    "highlights"
]

/// Developer-program terms that distinguish a program notice from Apple's
/// consumer "agreement updated" mail (Apple Card, Apple Business Manager) when
/// the subject does not name a known agreement. Matched against the subject and
/// the sender's display name and address.
private let developerProgramTerms = [
    "developer",
    "app store connect",
    "appstoreconnect",
    "paid applications",
    "paid apps",
    "xcode",
    "testflight"
]

/// Body phrasing that turns a plain "updated" notice into one the Account
/// Holder has to act on.
private let developerAgreementAcceptancePatterns = [
    "review and accept",
    "review and agree",
    "must accept",
    "must review",
    "accept the updated",
    "accept the new",
    "agree to the updated",
    "agree to the new"
]

/// Negations that cancel an acceptance phrase: "you do not need to review and
/// accept", "no action is required". Regular expressions over lowercased text.
private let developerAgreementNoActionPatterns = [
    #"\b(?:do not|don['’]t|no longer|won['’]t|will not) (?:need|have) to (?:review|accept|agree|sign|take)\b"#,
    #"\bno (?:further )?action (?:is |will be )?(?:required|needed|necessary)\b"#,
    #"\bnothing (?:further |else )?(?:is required|you need to do)\b"#
]

/// Display names for the agreements Apple sends program notices about, matched
/// case-insensitively and longest first so the Enterprise variant is not
/// reported as the plain Program agreement.
private let knownDeveloperAgreementNames = [
    "Apple Developer Enterprise Program License Agreement",
    "Apple Developer Program License Agreement",
    "Xcode and Apple SDKs Agreement",
    "Paid Applications Agreement",
    "Paid Applications Schedule",
    "Paid Apps Agreement",
    "Apple Developer Agreement"
]

/// Link text that is the notice's real call to action (the sign-in / review
/// link), handed to the builder's action resolver ahead of its generic
/// transactional patterns. Phrases are specific enough that the agreement's own
/// name link, "Acceptable Use Policy" and "Review Guidelines" do not match.
private let developerAgreementActionLinkPatterns = [
    "sign in",
    "log in",
    "view agreement",
    "review agreement",
    "review the agreement",
    "review the updated",
    "review and accept",
    "accept agreement",
    "accept the agreement",
    "accept the updated"
]
