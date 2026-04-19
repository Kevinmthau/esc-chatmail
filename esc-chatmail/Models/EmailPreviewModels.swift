import CoreGraphics
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

extension EmailPreviewClassification {
    var diagnosticSummary: String {
        let signalSummary = signals.map(\.rawValue).joined(separator: ",")
        return "kind=\(kind.rawValue) newsletter=\(newsletterScore) transactional=\(transactionalScore) signals=[\(signalSummary)]"
    }
}

enum NewsletterPreviewHeroImageDisplayMode: String, Equatable, Sendable {
    case fill
    case fit
}

extension NewsletterPreviewHeroImageDisplayMode {
    /// Falls back to the decoded image's actual aspect ratio when HTML metadata was
    /// too sparse to classify a banner-like hero image correctly.
    static func resolved(preferred: Self, imageSize: CGSize) -> Self {
        guard imageSize.width > 1, imageSize.height > 1 else {
            return preferred
        }

        if preferred == .fit {
            return .fit
        }

        let aspectRatio = imageSize.width / imageSize.height
        return aspectRatio >= 2.8 ? .fit : .fill
    }
}

struct NewsletterPreviewModel: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let snippet: String
    let heroImageURL: String?
    let heroImageDisplayMode: NewsletterPreviewHeroImageDisplayMode
    let sourceLabel: String?
    let sourceDomain: String?
}

enum TransactionalPreviewImageStyle: String, Equatable, Sendable {
    case avatar
    case card
}

struct TransactionalPreviewModel: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let amount: String?
    let status: String?
    let actionLabel: String?
    let detailLine: String?
    let imageURL: String?
    let imageStyle: TransactionalPreviewImageStyle
    let sourceLabel: String?
    let sourceDomain: String?
}

struct CalendarInvitePreviewModel: Equatable, Sendable {
    let title: String
    let monthSymbol: String
    let dayNumber: String
    let weekdaySymbol: String
    let dateTimeLine: String
    let locationLine: String?
    let organizerLine: String?
    let status: String?
    let actionLabel: String
    let sourceLabel: String?
}

enum NetlifyDeployStatus: String, Equatable, Sendable {
    case processing
    case ready
    case failed

    var displayText: String {
        switch self {
        case .processing: return "Processing"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

struct NetlifyDeployPreviewModel: Equatable, Sendable {
    let title: String
    let status: NetlifyDeployStatus
    let project: String
    let repoSlug: String?
    let commitSHA: String?
    let deployLogURL: String?
    let sourceLabel: String
}
