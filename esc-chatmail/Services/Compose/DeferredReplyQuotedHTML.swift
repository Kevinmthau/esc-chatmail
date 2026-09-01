import Foundation

/// Value-only inputs needed to recover the original HTML when MIME construction begins.
/// Capturing these on the managed-object context keeps Core Data out of background preflight.
struct ReplyQuotedHTMLSource: Sendable {
    let messageId: String
    let bodyStorageURI: String?
    let bodyText: String?
    let senderEmail: String?
    let subject: String?
}

/// Owns the HTML loader used by one reply-context builder. Actor ownership keeps
/// synchronous sanitization off MainActor and serializes concurrent reply preflight.
actor ReplyQuotedHTMLResolver {
    typealias LoadHTML = @Sendable (ReplyQuotedHTMLSource) -> String?

    private let contentLoader: HTMLContentLoader?
    private let customLoadHTML: LoadHTML?

    init(contentLoader: HTMLContentLoader) {
        self.contentLoader = contentLoader
        self.customLoadHTML = nil
    }

    init(loadHTML: @escaping LoadHTML) {
        self.contentLoader = nil
        self.customLoadHTML = loadHTML
    }

    func resolve(_ source: ReplyQuotedHTMLSource) -> String? {
        if let customLoadHTML {
            return customLoadHTML(source)
        }

        return contentLoader?.loadReplyQuotedOriginalHTML(
            messageId: source.messageId,
            bodyStorageURI: source.bodyStorageURI,
            bodyText: source.bodyText,
            senderEmail: source.senderEmail,
            subject: source.subject
        )
    }
}

struct DeferredReplyQuotedHTML: Sendable {
    let source: ReplyQuotedHTMLSource
    let resolver: ReplyQuotedHTMLResolver

    func resolve() async -> String? {
        await resolver.resolve(source)
    }
}
