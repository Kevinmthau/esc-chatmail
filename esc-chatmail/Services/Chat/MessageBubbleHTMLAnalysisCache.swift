import Foundation

private final class CachedMessageBubbleHTMLAnalysisBox {
    let value: MessageBubbleHTMLAnalysis

    init(_ value: MessageBubbleHTMLAnalysis) {
        self.value = value
    }
}

final class MessageBubbleHTMLAnalysisCache {
    static let shared = MessageBubbleHTMLAnalysisCache()

    private let cache = NSCache<NSString, CachedMessageBubbleHTMLAnalysisBox>()

    init() {
        cache.countLimit = 512
    }

    func value(forKey key: String) -> MessageBubbleHTMLAnalysis? {
        cache.object(forKey: key as NSString)?.value
    }

    func setValue(_ value: MessageBubbleHTMLAnalysis, forKey key: String) {
        cache.setObject(CachedMessageBubbleHTMLAnalysisBox(value), forKey: key as NSString)
    }
}
