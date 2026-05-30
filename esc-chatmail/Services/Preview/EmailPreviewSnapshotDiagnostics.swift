import CoreGraphics
import Foundation

struct EmailPreviewSnapshotDiagnosticCounts: Equatable {
    var cacheHits = 0
    var cacheMisses = 0
    var renderSuccesses = 0
    var renderFailures = 0
    var timeouts = 0
    var miniEmailWebViewFallbacks = 0
}

@MainActor
enum EmailPreviewSnapshotDiagnostics {
    private static var counts = EmailPreviewSnapshotDiagnosticCounts()

    static func logCacheHit(cacheKey: String, messageId: String?) {
        counts.cacheHits += 1
        log(
            "cache-hit",
            cacheKey: cacheKey,
            messageId: messageId,
            fields: ["count=\(counts.cacheHits)"]
        )
    }

    static func logCacheMiss(cacheKey: String, messageId: String?, reason: String) {
        counts.cacheMisses += 1
        log(
            "cache-miss",
            cacheKey: cacheKey,
            messageId: messageId,
            fields: [
                "count=\(counts.cacheMisses)",
                "reason=\(reason)"
            ]
        )
    }

    static func logRenderSuccess(
        cacheKey: String,
        messageId: String?,
        duration: TimeInterval,
        displayHeight: CGFloat,
        cacheStored: Bool
    ) {
        counts.renderSuccesses += 1
        log(
            "render-success",
            cacheKey: cacheKey,
            messageId: messageId,
            fields: [
                "count=\(counts.renderSuccesses)",
                "duration=\(durationDescription(duration))",
                "height=\(Int(displayHeight.rounded()))",
                "cacheStored=\(cacheStored)"
            ]
        )
    }

    static func logRenderFailure(
        cacheKey: String,
        messageId: String?,
        duration: TimeInterval,
        error: Error
    ) {
        counts.renderFailures += 1
        if isTimeout(error) {
            counts.timeouts += 1
        }

        log(
            "render-failure",
            cacheKey: cacheKey,
            messageId: messageId,
            fields: [
                "count=\(counts.renderFailures)",
                "timeouts=\(counts.timeouts)",
                "duration=\(durationDescription(duration))",
                "reason=\(failureReason(for: error))"
            ]
        )
    }

    static func logMiniEmailWebViewFallback(cacheKey: String, messageId: String?) {
        counts.miniEmailWebViewFallbacks += 1
        log(
            "fallback-mini-webview",
            cacheKey: cacheKey,
            messageId: messageId,
            fields: ["count=\(counts.miniEmailWebViewFallbacks)"]
        )
    }

    #if DEBUG
    static func resetForTesting() {
        counts = EmailPreviewSnapshotDiagnosticCounts()
    }

    static func countsForTesting() -> EmailPreviewSnapshotDiagnosticCounts {
        counts
    }
    #endif

    private static func log(
        _ event: String,
        cacheKey: String,
        messageId: String?,
        fields: [String]
    ) {
        var components = [
            "EmailPreviewSnapshot event=\(event)",
            "cacheKeyHash=\(cacheKeyHash(cacheKey))"
        ]

        if let messageId, !messageId.isEmpty {
            components.append("messageId=\(messageId)")
        }

        components.append(contentsOf: fields)
        Log.diagnostic(.htmlPreview, level: .info, components.joined(separator: " "), category: .ui)
    }

    private static func cacheKeyHash(_ cacheKey: String) -> String {
        String(EmailPreviewSnapshotCacheKey.filenameComponent(for: cacheKey).prefix(16))
    }

    private static func durationDescription(_ duration: TimeInterval) -> String {
        "\(Int((duration * 1000).rounded()))ms"
    }

    private static func isTimeout(_ error: Error) -> Bool {
        guard let renderError = error as? EmailPreviewSnapshotRenderError else {
            return false
        }

        if case .timeout = renderError {
            return true
        }

        return false
    }

    private static func failureReason(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }

        if let renderError = error as? EmailPreviewSnapshotRenderError {
            switch renderError {
            case .invalidWidth:
                return "invalid-width"
            case .navigationFailed(let underlyingError):
                let nsError = underlyingError as NSError
                return "navigation-failed:\(nsError.domain):\(nsError.code)"
            case .timeout:
                return "timeout"
            case .snapshotUnavailable:
                return "snapshot-unavailable"
            }
        }

        let nsError = error as NSError
        return "other:\(nsError.domain):\(nsError.code)"
    }
}
