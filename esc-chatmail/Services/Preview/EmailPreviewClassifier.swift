import Foundation

struct EmailPreviewClassifier {
    func classify(
        canonicalHTML: String,
        bodyText: String?,
        senderEmail: String?,
        subject: String? = nil
    ) -> EmailPreviewClassification {
        let lowercasedHTML = canonicalHTML.lowercased()
        let extractedText = normalizedBodyText(bodyText) ?? normalizedText(TextProcessing.extractPlainText(from: canonicalHTML))
        let lowercasedText = extractedText.lowercased()
        let metrics = HTMLMetrics(html: lowercasedHTML)
        let lowercasedSubject = subject?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let lowercasedSender = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        var newsletterScore = 0
        var transactionalScore = 0
        var signals: [EmailPreviewClassificationSignal] = []

        func addSignal(_ signal: EmailPreviewClassificationSignal) {
            if !signals.contains(signal) {
                signals.append(signal)
            }
        }

        if containsAny(newsletterFooterPatterns, in: lowercasedHTML) || containsAny(newsletterFooterPatterns, in: lowercasedText) {
            newsletterScore += 45
            addSignal(.unsubscribeFooter)
        }

        if containsAny(managePreferencePatterns, in: lowercasedHTML) || containsAny(managePreferencePatterns, in: lowercasedText) {
            newsletterScore += 20
            addSignal(.managePreferences)
        }

        if containsAny(viewInBrowserPatterns, in: lowercasedHTML) || containsAny(viewInBrowserPatterns, in: lowercasedText) {
            newsletterScore += 18
            addSignal(.viewInBrowser)
        }

        if containsAny(marketingFooterPatterns, in: lowercasedHTML) || containsAny(marketingFooterPatterns, in: lowercasedText) {
            newsletterScore += 12
            addSignal(.marketingFooter)
        }

        if canonicalHTML.count >= 16_000 {
            newsletterScore += 12
            addSignal(.largeHTMLBody)
        }

        if metrics.imageCount >= 4 {
            newsletterScore += 10
            addSignal(.manyImages)
        }

        if metrics.tableCount >= 4 {
            newsletterScore += 10
            addSignal(.manyTables)
        }

        if metrics.linkCount >= 10 {
            newsletterScore += 15
            addSignal(.manyLinks)
        }

        if containsAny(newsletterSenderPatterns, in: lowercasedSender) {
            newsletterScore += 18
            addSignal(.senderNewsletter)
        }

        if containsAny(digestSubjectPatterns, in: lowercasedSubject) {
            newsletterScore += 10
            addSignal(.subjectDigest)
        }

        if containsAny(callToActionPatterns, in: lowercasedHTML) || containsAny(callToActionPatterns, in: lowercasedText) {
            newsletterScore += 8
            addSignal(.callToActionLanguage)
        }

        if containsAny(transactionalPatterns, in: lowercasedHTML) || containsAny(transactionalPatterns, in: lowercasedText) {
            transactionalScore += 32
            addSignal(.transactionalKeywords)
        }

        if containsAny(noReplySenderPatterns, in: lowercasedSender) {
            transactionalScore += 12
            addSignal(.senderNoReply)
        }

        if containsAny(transactionalNoReplyLanguagePatterns, in: lowercasedHTML) ||
            containsAny(transactionalNoReplyLanguagePatterns, in: lowercasedText) {
            transactionalScore += 8
            addSignal(.noReplyLanguage)
        }

        if metrics.tableCount >= 1 && metrics.linkCount >= 1 {
            transactionalScore += 6
        }

        let hasReplyChainMarkers = containsAny(replyChainPatterns, in: lowercasedText)
        if hasReplyChainMarkers {
            newsletterScore -= 20
            transactionalScore -= 10
            addSignal(.replyChainMarkers)
        }

        let hasConversationalGreeting = containsAny(conversationalGreetingPatterns, in: lowercasedText)
        let hasPersonalSignOff = containsAny(personalSignOffPatterns, in: lowercasedText)
        let looksConversational = metrics.linkCount < 4 && metrics.tableCount <= 1 && (hasReplyChainMarkers || (hasConversationalGreeting && hasPersonalSignOff))

        if looksConversational {
            newsletterScore -= 18
            transactionalScore -= 8
            if hasConversationalGreeting {
                addSignal(.conversationalGreeting)
            }
        }

        newsletterScore = max(newsletterScore, 0)
        transactionalScore = max(transactionalScore, 0)

        let kind: EmailPreviewKind
        if newsletterScore >= 55 && newsletterScore >= transactionalScore + 10 {
            kind = .newsletter
        } else if transactionalScore >= 30 {
            kind = .transactional
        } else {
            kind = .personToPerson
        }

        return EmailPreviewClassification(
            kind: kind,
            newsletterScore: newsletterScore,
            transactionalScore: transactionalScore,
            signals: signals
        )
    }

    private func normalizedBodyText(_ bodyText: String?) -> String? {
        guard let bodyText else { return nil }
        return normalizedText(RawEmailSourceSanitizer.extractDisplayText(from: bodyText))
    }

    private func normalizedText(_ text: String) -> String {
        HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ patterns: [String], in text: String) -> Bool {
        patterns.contains { text.contains($0) }
    }
}

private struct HTMLMetrics {
    let imageCount: Int
    let tableCount: Int
    let linkCount: Int

    init(html: String) {
        imageCount = HTMLMetrics.countOccurrences(of: "<img", in: html)
        tableCount = HTMLMetrics.countOccurrences(of: "<table", in: html)
        linkCount = HTMLMetrics.countOccurrences(of: "<a ", in: html)
    }

    private static func countOccurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return text.components(separatedBy: token).count - 1
    }
}

private let newsletterFooterPatterns = [
    "unsubscribe",
    "manage subscriptions",
    "manage your subscription",
    "email preferences",
    "update your preferences"
]

private let managePreferencePatterns = [
    "manage preferences",
    "manage subscription",
    "manage subscriptions",
    "subscription preferences"
]

private let viewInBrowserPatterns = [
    "view in browser",
    "view online",
    "open in browser",
    "read this online"
]

private let marketingFooterPatterns = [
    "privacy policy",
    "all rights reserved",
    "why did i get this email",
    "mailing address",
    "follow us"
]

private let newsletterSenderPatterns = [
    "newsletter@",
    "news@",
    "digest@",
    "brief@",
    "marketing@",
    "promotions@",
    "updates@"
]

private let noReplySenderPatterns = [
    "noreply@",
    "no-reply@",
    "donotreply@",
    "do-not-reply@",
    "notifications@",
    "alerts@"
]

private let digestSubjectPatterns = [
    "newsletter",
    "digest",
    "brief",
    "edition",
    "daily",
    "weekly"
]

private let callToActionPatterns = [
    "read more",
    "learn more",
    "shop now",
    "view more",
    "see more",
    "continue reading"
]

private let transactionalPatterns = [
    "receipt",
    "invoice",
    "reservation number",
    "reservation has been canceled",
    "reservation has been cancelled",
    "reservation confirmation",
    "reservation cancellation",
    "reservation canceled",
    "reservation cancelled",
    "order confirmation",
    "order confirmed",
    "tracking number",
    "statement",
    "statement is ready",
    "password reset",
    "security alert",
    "security notice",
    "verify your",
    "confirm your",
    "one-time passcode",
    "one time passcode",
    "billing",
    "account activity",
    "account number ending",
    "account ending in",
    "service message",
    "you paid",
    "paid you",
    "money credited",
    "credited to your",
    "payment received",
    "payment sent",
    "payment completed",
    "transfer completed",
    "transfer confirmation",
    "deposit declined",
    "deposit confirmation",
    "deposit completed",
    "daily deposit limit",
    "mobile check deposit",
    "transaction details",
    "transaction id",
    "payment method",
    "see transaction"
]

private let transactionalNoReplyLanguagePatterns = [
    "do not reply",
    "don't reply",
    "do not respond",
    "don't respond",
    "please do not reply",
    "please do not respond"
]

private let replyChainPatterns = [
    "\non ",
    " wrote:",
    "from:",
    "sent from my iphone",
    "sent from my ipad"
]

private let conversationalGreetingPatterns = [
    "hi ",
    "hello ",
    "hey ",
    "good morning",
    "good afternoon"
]

private let personalSignOffPatterns = [
    "\nthanks",
    "\nthank you",
    "\nbest",
    "\ncheers",
    "\nregards"
]
