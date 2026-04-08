import Foundation

enum EmailPreviewKind: String, Equatable, Sendable {
    case personToPerson
    case transactional
    case newsletter
}

enum EmailPreviewClassificationSignal: String, Equatable, Sendable {
    case unsubscribeFooter
    case managePreferences
    case viewInBrowser
    case marketingFooter
    case largeHTMLBody
    case manyImages
    case manyTables
    case manyLinks
    case senderNewsletter
    case senderNoReply
    case subjectDigest
    case transactionalKeywords
    case callToActionLanguage
    case replyChainMarkers
    case conversationalGreeting
}

struct EmailPreviewClassification: Equatable, Sendable {
    let kind: EmailPreviewKind
    let newsletterScore: Int
    let transactionalScore: Int
    let signals: [EmailPreviewClassificationSignal]
}

struct NewsletterPreviewModel: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let snippet: String
    let heroImageURL: String?
    let sourceLabel: String?
    let sourceDomain: String?
}
