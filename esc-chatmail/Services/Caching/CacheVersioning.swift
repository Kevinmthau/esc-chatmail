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
    /// The persisted rich-content verdict is versioned separately, by
    /// `richContentVerdictEpoch`: a cleanup change usually needs both bumped.
    static let chatPreviewDerivationVersion = "2026-09-17-signature-front-core-v1"

    /// Epoch of persisted rich-content verdicts (`RichContentVerdict.storedValue`,
    /// `Message.richContentVerdict`). Bump whenever `RichContentVerdictResolver`
    /// could answer differently for the same stored state: a change to
    /// `RichContentClassifier`, to the cleanup chain behind
    /// `ChatBubbleTextProcessor.cleanedHTMLForProcessing` (quote and signature
    /// removal), to `NewsletterFallbackText.looksLikeFallbackText`, to
    /// `RawEmailSourceSanitizer.extractHTMLText` or
    /// `ChatBubbleTextProcessor.containsHTMLTags`, or to the resolver's
    /// has-HTML-source rule.
    ///
    /// A bump makes every stored verdict read as unknown at once, so bubbles
    /// fall back to the loading pill rather than rendering the old code's
    /// answer, and re-arms the launch backfill, whose migration key embeds it
    /// (`ConversationLaunchRepairCoordinator.richContentVerdictBackfillMigrationKey`).
    /// A missed bump is not permanent either: a bubble load that disagrees with
    /// the stored verdict has it recomputed (`MessageBubbleLoader.loadContent`).
    /// Valid range 1...16383: the stored value is an Int16 holding `epoch * 2 + bit`.
    static let richContentVerdictEpoch: Int16 = 1

    /// Embedded in email preview snapshot cache keys. Bump when the preview
    /// renderer's visual output changes.
    static let previewSnapshotRendererVersion = "snapshot-v4"
}
