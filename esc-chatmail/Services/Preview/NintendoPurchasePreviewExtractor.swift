import Foundation

/// Card fields read from a Nintendo purchase receipt or membership
/// automatic-renewal notice.
struct NintendoPurchaseNotice: Equatable {
    let title: String
    let subtitle: String?
    let amount: String?
    let status: String
    let detailLine: String?
}

/// Detects Nintendo Account purchase receipts ("Thank you for your recent
/// digital purchase from Nintendo", with a `Transaction ID:` line) and Nintendo
/// Switch Online automatic-renewal notices, and reads their labeled fields into
/// a summary card.
///
/// Both mails are plain label/value text ("Transaction ID: …", "Price (subject
/// to applicable taxes): $49.99", "Deadline to turn off automatic renewal:
/// …") with long how-to and legal sections and no headings, images or action
/// links, so the generic transactional builder had nothing to anchor on and the
/// chat showed the rendered-HTML snapshot: two screens of serif body text per
/// message. The fields are read from the full body, not the builder's capped
/// preview lines: the receipt's total sits below the family-membership and
/// renewal how-to sections.
///
/// Shared helpers (truncation, amount parsing) are injected so the extractor
/// keeps the builder's exact formatting, as `AppStoreNotificationPreviewExtractor`
/// does.
struct NintendoPurchasePreviewExtractor {
    private let lineProcessor: PreviewLineProcessor
    private let firstAmount: (String?) -> String?

    init(
        lineProcessor: PreviewLineProcessor,
        firstAmount: @escaping (String?) -> String?
    ) {
        self.lineProcessor = lineProcessor
        self.firstAmount = firstAmount
    }

    /// Nintendo sends account mail from `accounts.nintendo.com` and eShop mail
    /// from `nintendo.net`; anchoring on the parsed sender domain keeps
    /// lookalikes ("nintendo.com.example.org") and display-name forgeries out.
    static let nintendoSenderDomainSuffixes: Set<String> = ["nintendo.com", "nintendo.net"]

    /// The text the gate and the field reader both run on: the plain-text body
    /// first (its label lines win the first-occurrence lookup), then the
    /// HTML-derived text, then the canonical HTML's own text when neither was
    /// extracted. The pipeline's route and the builder must pass the same
    /// sources, or the route could pick the transactional card for a message
    /// the builder then refuses.
    static func noticeText(plainText: String?, extractedText: String?, canonicalHTML: String?) -> String {
        let texts = [plainText, extractedText].compactMap(PreviewTextUtilities.normalizedPreviewText)
        if !texts.isEmpty {
            return texts.joined(separator: "\n")
        }

        guard let canonicalHTML else { return "" }
        return PreviewTextUtilities.normalizedText(TextProcessing.extractPlainText(from: canonicalHTML))
    }

    /// Whether the message is a Nintendo purchase receipt or renewal notice.
    ///
    /// Gated on the sender domain *and* a field only these system mails carry,
    /// so Nintendo's newsletters and sale announcements stay newsletters.
    /// Replies and forwards are refused outright: a support thread quoting a
    /// receipt is a conversation, not a receipt. The classifier's reply-chain
    /// signal is deliberately not consulted: it is a body-substring match
    /// ("\non ", "from:") that Nintendo's own instruction lines ("On your PC or
    /// smart device") can trip, so the explicit quote markers below stand in
    /// for it.
    static func isPurchaseNotice(senderEmail: String?, subject: String?, noticeText: String) -> Bool {
        guard PreviewTextUtilities.senderDomain(senderEmail, matchesDomainOrSuffixIn: nintendoSenderDomainSuffixes) else {
            return false
        }

        let lowercasedSubject = PreviewTextUtilities.normalizedComparableText(subject)
        guard lowercasedSubject.range(of: #"^(?:re|fw|fwd)\s*:"#, options: .regularExpression) == nil else {
            return false
        }

        let lowercasedText = noticeText.lowercased()
        guard !quotedConversationMarkers.contains(where: lowercasedText.contains) else {
            return false
        }

        guard noticeKind(in: lowercasedText) != nil else {
            return false
        }

        return !reportsOtherOutcome(lowercasedSubject: lowercasedSubject, lowercasedText: lowercasedText)
    }

    /// A refund, cancelled order, declined payment, lapsed renewal or support
    /// reply can carry these same labeled fields, and the card's fixed status
    /// ("Purchased", "Auto-Renewal") would then state the opposite of the mail.
    /// Only the subject and the lead-in above the first field are read: the
    /// how-to and legal sections below the fields can use these words on a
    /// genuine notice. A mail this refuses takes the classifier's route, as any
    /// other Nintendo mail does.
    private static func reportsOtherOutcome(lowercasedSubject: String, lowercasedText: String) -> Bool {
        let firstField = lowercasedText.range(of: noticeFieldPattern, options: .regularExpression)
        let leadIn = firstField.map { String(lowercasedText[..<$0.lowerBound]) } ?? ""
        return [lowercasedSubject, leadIn].contains { text in
            text.range(of: otherOutcomePattern, options: .regularExpression) != nil
        }
    }

    /// The card for a purchase notice, or nil when `isPurchaseNotice` refuses
    /// the message.
    func notice(
        senderEmail: String?,
        subject: String?,
        noticeText: String
    ) -> NintendoPurchaseNotice? {
        guard Self.isPurchaseNotice(senderEmail: senderEmail, subject: subject, noticeText: noticeText),
              let kind = Self.noticeKind(in: noticeText.lowercased()) else {
            return nil
        }

        let fields = Self.labeledFields(in: noticeText)
        switch kind {
        case .purchase:
            return purchaseNotice(fields: fields, subject: subject)
        case .automaticRenewal:
            return automaticRenewalNotice(fields: fields, subject: subject, noticeText: noticeText)
        }
    }

    private enum NoticeKind {
        case purchase
        case automaticRenewal
    }

    /// A purchase receipt also mentions automatic renewal (where to find the
    /// turn-off deadline), so a transaction ID decides the receipt first.
    private static func noticeKind(in lowercasedText: String) -> NoticeKind? {
        if lowercasedText.range(of: transactionIDFieldPattern, options: .regularExpression) != nil,
           purchaseMarkers.contains(where: lowercasedText.contains) {
            return .purchase
        }

        if automaticRenewalMarkers.contains(where: lowercasedText.contains) {
            return .automaticRenewal
        }

        return nil
    }

    private func purchaseNotice(
        fields: [String: String],
        subject: String?
    ) -> NintendoPurchaseNotice {
        let itemName = Self.firstValue(for: purchasedItemLabels, in: fields)
        let (title, subtitle) = titleAndPlan(from: itemName, subject: subject, fallback: "Nintendo purchase")

        let transactionDate = Self.firstValue(for: ["transaction date", "purchase date", "date"], in: fields)
            .flatMap(Self.datePart)
        let transactionID = Self.firstValue(for: ["transaction id"], in: fields)
            .map { "Transaction ID \($0)" }
        let detailSegments = [transactionDate, transactionID].compactMap { $0 }

        return NintendoPurchaseNotice(
            title: title,
            subtitle: subtitle,
            amount: amount(for: purchaseAmountLabels, in: fields),
            status: "Purchased",
            detailLine: detailSegments.isEmpty
                ? nil
                : lineProcessor.truncate(detailSegments.joined(separator: " • "), limit: 90)
        )
    }

    private func automaticRenewalNotice(
        fields: [String: String],
        subject: String?,
        noticeText: String
    ) -> NintendoPurchaseNotice {
        // Read line by line: joined lines would run a heading ("Manage your
        // account") into the sentence below it. A sentence hard-wrapped across
        // lines looks the same as that, so it falls back to the subject.
        let membershipName = Self.nonEmptyLines(in: noticeText).lazy
            .compactMap { Self.firstRegexCapture(in: $0, pattern: membershipSentencePattern) }
            .first
        let (title, subtitle) = titleAndPlan(
            from: membershipName,
            subject: subject,
            fallback: "Nintendo Switch Online membership"
        )

        let deadline = Self.firstValue(for: ["deadline to turn off automatic renewal"], in: fields)
            .map(Self.normalizedTimestamp)
        let renewalTerm = Self.firstValue(for: ["automatic renewal term"], in: fields)
            .map { "Renews every \(Self.expandedTerm($0))" }
        let detailLine = deadline.map { "Turn off auto-renewal by \($0)" } ?? renewalTerm

        return NintendoPurchaseNotice(
            title: title,
            subtitle: subtitle,
            amount: amount(for: ["price", "renewal price", "amount"], in: fields),
            status: "Auto-Renewal",
            detailLine: detailLine.map { lineProcessor.truncate($0, limit: 90) }
        )
    }

    /// "Nintendo Switch Online + Expansion Pack individual 12-month (365-day)
    /// membership" reads as a product name followed by its plan; the card shows
    /// the product as the title and the plan beneath it. "Membership" must follow
    /// the plan word, or a game ("Super Mario Family Party") would lose the end
    /// of its name to a plan it does not have.
    private func titleAndPlan(
        from itemName: String?,
        subject: String?,
        fallback: String
    ) -> (title: String, subtitle: String?) {
        if let itemName,
           let captures = Self.firstRegexCaptures(
            in: itemName,
            pattern: #"^(.+?)\s+((?:individual|family)\b.*\bmembership\b.*)$"#
           ),
           captures.count == 2 {
            return (
                lineProcessor.truncate(captures[0], limit: 90),
                lineProcessor.truncate(Self.capitalizingFirstLetter(captures[1]), limit: 90)
            )
        }

        if let itemName {
            return (lineProcessor.truncate(itemName, limit: 90), nil)
        }

        let normalizedSubject = PreviewTextUtilities.normalizedText(subject)
        return (normalizedSubject.isEmpty ? fallback : lineProcessor.truncate(normalizedSubject, limit: 90), nil)
    }

    private func amount(for labels: [String], in fields: [String: String]) -> String? {
        for label in labels {
            if let amount = firstAmount(fields[label]) {
                return amount
            }
        }
        return nil
    }

    /// `Label: value` lines, keyed by the lowercased label with any
    /// parenthetical dropped ("Price (subject to applicable taxes)" → "price").
    /// A label alone on its line takes the next line as its value, for HTML
    /// templates that stack the two in separate blocks (table cells extract onto
    /// one line), unless that line is itself a field or a link. A colon between
    /// digits is a clock time ("06:58"), so it doesn't count. The first occurrence
    /// wins.
    private static func labeledFields(in text: String) -> [String: String] {
        let lines = nonEmptyLines(in: text)
        var fields: [String: String] = [:]

        for (index, line) in lines.enumerated() {
            guard let captures = firstRegexCaptures(
                in: line,
                pattern: #"^[•▼*\-\s]*([^:]{2,60}?)\s*:\s*(.*)$"#,
                allowsEmptyCaptures: true
            ),
                  captures.count == 2 else {
                continue
            }

            let label = captures[0]
                .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !label.isEmpty, !label.contains("http"), fields[label] == nil else {
                continue
            }

            var value = captures[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty, index + 1 < lines.count,
               lines[index + 1].range(of: #"(?<!\d):|:(?!\d)"#, options: .regularExpression) == nil {
                value = lines[index + 1]
            }
            guard !value.isEmpty, !value.lowercased().hasPrefix("//") else {
                continue
            }

            fields[label] = value
        }

        return fields
    }

    private static func nonEmptyLines(in text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { PreviewTextUtilities.normalizedText($0) }
            .filter { !$0.isEmpty }
    }

    private static func firstValue(for labels: [String], in fields: [String: String]) -> String? {
        labels.lazy.compactMap { fields[$0] }.first
    }

    /// "11/1/2026 05:58:10 (24H PST)" → "11/1/2026".
    private static func datePart(_ timestamp: String) -> String? {
        firstRegexCapture(in: timestamp, pattern: #"(\d{1,2}/\d{1,2}/\d{2,4})"#) ?? normalizedTimestamp(timestamp)
    }

    /// "10/30/2027 06:58 (24H PDT)" → "10/30/2027 06:58 PDT".
    private static func normalizedTimestamp(_ timestamp: String) -> String {
        timestamp
            .replacingOccurrences(of: #"\(\s*24H\s+([A-Za-z]{2,5})\s*\)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "365 d" → "365 days".
    private static func expandedTerm(_ term: String) -> String {
        term.replacingOccurrences(of: #"^(\d+)\s*d$"#, with: "$1 days", options: .regularExpression)
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        firstRegexCaptures(in: text, pattern: pattern)?.first
    }

    private static func firstRegexCaptures(
        in text: String,
        pattern: String,
        allowsEmptyCaptures: Bool = false
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else {
            return nil
        }

        var captures: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let captureRange = Range(match.range(at: index), in: text) else {
                return nil
            }
            let capture = text[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowsEmptyCaptures || !capture.isEmpty else {
                return nil
            }
            captures.append(capture)
        }
        return captures
    }
}

/// Quoted history inside the body: a reply or forward that carries a receipt.
private let quotedConversationMarkers = [
    " wrote:",
    "-----original message-----",
    "---------- forwarded message"
]

private let transactionIDFieldPattern = #"\btransaction id\s*:"#

/// The receipt's own sentence and item labels (with their colons). A bare
/// "nintendo eshop" or "purchase from nintendo" is not enough: how-to sections
/// and support mail say those about a transaction that was no purchase. A real
/// receipt worded differently falls back to the classifier's route, which only
/// costs it the summary card.
private let purchaseMarkers = [
    "digital purchase from nintendo",
    "purchased membership:",
    "purchased item:",
    "purchased items:"
]

/// Field labels, with their colons, that only the renewal notice carries: the
/// receipt says where to find the deadline ("…automatic renewal in the
/// following locations"), and a sale mail can urge setting renewal on.
private let automaticRenewalMarkers = [
    "automatic renewal term:",
    "deadline to turn off automatic renewal:"
]

/// Where a notice's labeled fields begin; `reportsOtherOutcome` reads above it.
private let noticeFieldPattern = ([transactionIDFieldPattern] + automaticRenewalMarkers)
    .joined(separator: "|")

/// The renewal notice's "Your <membership> is set for automatic renewal", run on
/// one line. The capture stops at sentence punctuation and starts after the last
/// "your", so an earlier one in a greeting cannot stretch it.
private let membershipSentencePattern =
    #"\byour\s+((?:(?!\byour\b)[^.:]){3,120}?)\s+is\s+(?:now\s+)?set\s+for\s+automatic\s+renewal"#

/// Word stems that say the transaction did not end as a purchase or a live renewal.
private let otherOutcomePattern =
    #"\b(?:refund|cancel|declin|fail|unsuccessful|unable|could not|couldn['’]t|turned off|expired|support)"#

private let purchasedItemLabels = [
    "purchased membership",
    "purchased item",
    "purchased items",
    "purchased content",
    "item name",
    "item",
    "product"
]

/// Highest-priority first: a receipt that lists a subtotal and a total shows
/// what was charged.
private let purchaseAmountLabels = [
    "total",
    "total amount",
    "total price",
    "amount paid",
    "amount",
    "price",
    "subtotal"
]
