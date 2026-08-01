import Foundation

/// Central home for cache version constants (the perf plan's C6
/// prerequisite): a coordinated invalidation of derived-content caches is a
/// version bump here, in one place.
///
/// Caches whose keys embed a source signature (RenderedMessageCache,
/// HTMLContentResultCache) version implicitly through the signature and have
/// no constant here.
enum CacheVersioning {
    /// Embedded in every ProcessedTextCache key. Bump when text-processing
    /// output changes shape (classification, signature/quote removal, chat
    /// preview derivation).
    static let processedTextProcessingVersion = "2026-08-01-bottom-post-recovery-v1"

    /// Embedded in email preview snapshot cache keys. Bump when the preview
    /// renderer's visual output changes.
    static let previewSnapshotRendererVersion = "snapshot-v4"
}
