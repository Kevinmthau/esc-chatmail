import Foundation

/// Central home for cache version constants (the perf plan's C6
/// prerequisite): a coordinated invalidation of derived-content caches is a
/// version bump here, in one place.
///
/// Caches whose keys embed a source signature (RenderedMessageCache,
/// HTMLContentResultCache) version implicitly through the signature and have
/// no constant here.
enum CacheVersioning {
    /// Versions persisted received-HTML bubble text. Bump when chat preview
    /// derivation output changes shape (classification, signature/quote
    /// removal) so `ChatPreviewRepair` re-derives stored previews. The
    /// in-memory caches need no constant: they start empty on every launch.
    static let chatPreviewDerivationVersion = "2026-09-10-repeated-signature-v1"

    /// Embedded in email preview snapshot cache keys. Bump when the preview
    /// renderer's visual output changes.
    static let previewSnapshotRendererVersion = "snapshot-v4"
}
