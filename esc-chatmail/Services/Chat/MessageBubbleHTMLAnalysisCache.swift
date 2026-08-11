import Foundation

private final class CachedMessageBubbleHTMLAnalysisBox {
    let value: MessageBubbleHTMLAnalysis

    init(_ value: MessageBubbleHTMLAnalysis) {
        self.value = value
    }
}

struct MessageBubbleHTMLAnalysisAccountGeneration: Equatable, Sendable {
    fileprivate let value: UInt64
}

final class MessageBubbleHTMLAnalysisCache {
    static let shared = MessageBubbleHTMLAnalysisCache()

    private let cache = NSCache<NSString, CachedMessageBubbleHTMLAnalysisBox>()
    private let lock = NSLock()
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0

    init() {
        cache.countLimit = 512
    }

    func value(forKey key: String) -> MessageBubbleHTMLAnalysis? {
        value(forKey: key, expectedGeneration: nil)
    }

    func value(
        forKey key: String,
        expectedGeneration: MessageBubbleHTMLAnalysisAccountGeneration?
    ) -> MessageBubbleHTMLAnalysis? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsAccountWork else { return nil }
        if let expectedGeneration,
           expectedGeneration.value != accountGeneration {
            return nil
        }
        return cache.object(forKey: key as NSString)?.value
    }

    func setValue(_ value: MessageBubbleHTMLAnalysis, forKey key: String) {
        setValue(value, forKey: key, expectedGeneration: nil)
    }

    func setValue(
        _ value: MessageBubbleHTMLAnalysis,
        forKey key: String,
        expectedGeneration: MessageBubbleHTMLAnalysisAccountGeneration?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsAccountWork else { return }
        if let expectedGeneration,
           expectedGeneration.value != accountGeneration {
            return
        }
        cache.setObject(CachedMessageBubbleHTMLAnalysisBox(value), forKey: key as NSString)
    }

    func captureAccountGeneration() -> MessageBubbleHTMLAnalysisAccountGeneration? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsAccountWork else { return nil }
        return MessageBubbleHTMLAnalysisAccountGeneration(value: accountGeneration)
    }

    func isAccountGenerationCurrent(
        _ generation: MessageBubbleHTMLAnalysisAccountGeneration
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsAccountWork && generation.value == accountGeneration
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func closeAccountWorkAndClear() {
        lock.lock()
        acceptsAccountWork = false
        accountGeneration &+= 1
        cache.removeAllObjects()
        lock.unlock()
    }

    func reopenAccountWork() {
        lock.lock()
        accountGeneration &+= 1
        acceptsAccountWork = true
        lock.unlock()
    }
}
