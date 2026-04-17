import Foundation

@MainActor
final class MessageBubbleViewModel: ObservableObject {
    @Published private(set) var senderName: String?
    @Published private(set) var senderAvatarURL: String?
    @Published private(set) var senderImageData: Data?
    @Published private(set) var hasRichHTMLContent = false
    @Published private(set) var fullTextContent: String?
    @Published private(set) var hasLoadedContent = false
    @Published private(set) var sharedDocumentLinks: [SharedDocumentLink] = []
    @Published private(set) var forwardedDisplayContent: ForwardedMessageDisplayContent?
    @Published private(set) var htmlAnalysis: MessageBubbleHTMLAnalysis = .empty

    private let loader: any MessageBubbleLoading
    private var loadingMessageID: String?
    private var lastContentSignature: String?

    init(loader: any MessageBubbleLoading) {
        self.loader = loader
    }

    convenience init(deps: Dependencies) {
        self.init(loader: deps.makeMessageBubbleLoader())
    }

    func loadIfNeeded(using context: MessageBubbleLoadContext) async {
        if hasLoadedContent,
           loadingMessageID == context.messageID,
           lastContentSignature == context.contentSignature {
            return
        }

        loadingMessageID = context.messageID
        lastContentSignature = context.contentSignature
        hasLoadedContent = false
        fullTextContent = nil
        hasRichHTMLContent = false
        sharedDocumentLinks = []
        forwardedDisplayContent = nil
        htmlAnalysis = .placeholder(hasHTMLSource: context.contentRequest.hasHTMLSource)
        senderAvatarURL = nil
        senderImageData = nil

        if let prefetchedSenderName = context.prefetchedSenderName {
            senderName = prefetchedSenderName
        } else if context.senderRequest != nil {
            senderName = nil
        } else if context.senderRequest == nil {
            senderName = nil
            senderAvatarURL = nil
            senderImageData = nil
        }

        if let senderRequest = context.senderRequest {
            async let senderResult = loader.loadSenderInfo(from: senderRequest)
            async let contentResult = loader.loadContent(from: context.contentRequest)
            let loadedSender = await senderResult
            guard isStillActive(context) else { return }
            senderName = loadedSender.name ?? context.prefetchedSenderName
            senderAvatarURL = loadedSender.avatarURL
            senderImageData = loadedSender.imageData

            let loadedContent = await contentResult
            guard isStillActive(context) else { return }
            apply(loadedContent)
            return
        }

        let contentResult = await loader.loadContent(from: context.contentRequest)
        guard isStillActive(context) else { return }
        apply(contentResult)
    }

    private func apply(_ contentResult: MessageBubbleContentResult) {
        fullTextContent = contentResult.fullTextContent
        hasRichHTMLContent = contentResult.hasRichHTMLContent
        sharedDocumentLinks = contentResult.sharedDocumentLinks
        forwardedDisplayContent = contentResult.forwardedDisplayContent
        htmlAnalysis = contentResult.htmlAnalysis
        hasLoadedContent = true
    }

    private func isStillActive(_ context: MessageBubbleLoadContext) -> Bool {
        guard !Task.isCancelled else { return false }
        return loadingMessageID == context.messageID && lastContentSignature == context.contentSignature
    }
}
