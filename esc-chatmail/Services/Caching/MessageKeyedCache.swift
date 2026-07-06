import Foundation

/// Shared invalidation vocabulary for the message-keyed caches.
enum MessageCacheInvalidationReason: String, Sendable {
    /// The message entity was deleted.
    case messageDeleted
    /// The message's source content changed (new/edited HTML, attachments).
    case contentChanged
    /// Caller-initiated invalidation without a more specific cause.
    case explicit
}

/// A cache keyed — directly or via a tracked messageID → cache-keys index —
/// by message ID. Conforming caches drop every entry derived from the
/// message. `reason` is diagnostic; caches that don't record a reason may
/// ignore it.
protocol MessageKeyedCache {
    func invalidate(messageId: String, reason: MessageCacheInvalidationReason) async
}

extension ProcessedTextCache: MessageKeyedCache {
    func invalidate(messageId: String, reason: MessageCacheInvalidationReason) async {
        await invalidate(messageId: messageId)
    }
}

extension RenderedMessageCache: MessageKeyedCache {
    func invalidate(messageId: String, reason: MessageCacheInvalidationReason) {
        invalidate(messageId: messageId, sourceSignature: nil, reason: .explicit)
    }
}

extension HTMLContentLoader: MessageKeyedCache {
    func invalidate(messageId: String, reason: MessageCacheInvalidationReason) {
        invalidate(messageId: messageId)
    }
}

extension HTMLContentResultCache: MessageKeyedCache {
    func invalidate(messageId: String, reason: MessageCacheInvalidationReason) {
        invalidate(messageId: messageId, matching: { _ in true })
    }
}
