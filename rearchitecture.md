# Email Rendering Rearchitecture Closeout

Last audited: 2026-05-31

`esc-chatmail` now has the major rendering rearchitecture pieces in place:
DOM-backed HTML processing for migrated paths, persisted chat preview text,
snapshot-backed rich previews, shared parsed-email facts, render artifact
caching, eager inline CID attachment fetching, and documented dark-mode
behavior. This document records the final status and the current architecture so
future changes can start from the shipped system rather than the old roadmap.

## Final Recommendation Status

| # | Recommendation | Status | Current outcome | Deferred or remaining work |
|---|---|---|---|---|
| 1 | Adopt a proper HTML DOM parser | Complete | SwiftSoup is wrapped by `EmailDocument`. Quote removal, HTML text extraction, dangerous-element/event-handler removal, preview DOM queries, render-quality facts, and inline `cid:` enumeration use DOM-backed paths. | Specialized URL, CSS, tracking-pixel, and regex parse-failure safety paths intentionally remain. Revisit only when replacing a specific safety pass with equal fixture coverage. |
| 2 | Single canonical `ParsedEmail` pass per message | Partially complete | `ParsedEmailProvider` caches immutable read-only facts by `messageId + sourceSignature`. `EmailPreviewSourceLoader`, `EmailPreviewClassifier`, `MessageBubbleHTMLAnalysisBuilder`, and `EmailRenderQualityEvaluator` use it for migrated facts. | Mutating sanitizer/wrapper paths still parse independently by design. Raw builder entry points remain for tests and compatibility. Revisit consumer by consumer when a call site can consume existing facts without changing visible output. |
| 3 | Collapse the plain-text pipeline | Partially complete | Normal personal-message bubbles use persisted `Message.chatPreviewText`; `MessageContentView` resolves stored preview text before runtime fallback text. HTML-backed old records use the DOM HTML compatibility path. | `PlainTextQuoteRemover` and `PlainTextSignatureRemover` remain for true plain-text-only mail, old records with blank `chatPreviewText`, and forwarded lead-in compatibility. Revisit after a data backfill or metrics show missing stored previews are rare enough to narrow further. |
| 4 | Replace `MiniEmailWebView` with snapshots | Complete | Long-tail rich HTML preview models return `.html` payloads consumed by `EmailPreviewSnapshotView`. Snapshot images are disk cached and rendered once per variant. | `MiniEmailWebView` remains only as snapshot-render failure fallback. Revisit if `fallback-mini-webview` diagnostics become common. |
| 5 | Unify rendering caches behind a coordinator | Partially complete | `RenderedMessageCache` owns in-memory derived render artifacts: preview source, preview render model, wrapped preview/original HTML, bubble analysis, rich-content classification, legacy fallback text, and snapshot metadata. | `HTMLContentLoader.htmlCache`, `ProcessedTextCache`, and `MessageBubbleHTMLAnalysisCache` remain intentional compatibility or low-level caches. Revisit after each remaining producer can move behind `RenderedMessageCache` with focused tests. |
| 6 | Pick one canonical preview text per message at ingest | Complete | Synced, optimistic, and batch-created messages populate `Message.chatPreviewText`. Stored preview text wins for normal chat bubbles. | Legacy fallback stays only for old/blank records. |
| 7 | Memoize `MessageBubble.loadSignature` | Complete | `ChatMessageRowModel` precomputes text fingerprints; `MessageBubble.loadSignature` no longer hashes large text fields on every body evaluation. | None. |
| 8 | Eagerly fetch inline attachments at ingest | Complete | `MessageProcessor` records normalized inline CID prefetch targets from MIME metadata and DOM-backed HTML references. `MessagePersister` schedules post-save eager downloads through `InlineCIDAttachmentPrefetcher`. | `CIDSchemeHandler` remains the display-time fallback when eager fetch misses, fails, lacks metadata, or cache files are cleared. |
| 9 | Document dark-mode policy | Complete | Preview, original-email, WebView trait, and snapshot policies are documented in `HTMLDisplayWrapper`, `BaseEmailWebView`, `EmailPreviewSnapshotRenderer`, and this file. | None. |
| 10 | Server-side preprocessing | Deferred | No server preprocessing was introduced. Local rendering remains the source of truth. | Revisit only if local CPU, memory, or energy cost remains a product issue after the client-side parsed/render cache paths have soaked. |

No recommendation is rejected. Some broad recommendations were narrowed because
the remaining code is an intentional fallback or a mutating safety pass rather
than dead code.

## Current Architecture

### Ingestion Flow

1. `MessageProcessor.processGmailMessage` traverses Gmail MIME parts, fetches
   large bodies, extracts headers, attachments, snippets, canonical content, and
   newsletter/promotion signals.
2. HTML content is saved through `HTMLContentHandler`; canonical source metadata
   is carried on `ProcessedMessage`.
3. `Message.chatPreviewText` is computed at ingest. HTML-backed previews use the
   DOM path through `HTMLQuoteRemover` / `TextProcessing.extractPlainText`; true
   plain-text-only inputs use the named legacy fallback path.
4. Inline CID prefetch targets are collected from MIME `Content-ID` attachment
   metadata and DOM-backed HTML `cid:` references.
5. `MessagePersister` writes Core Data rows and schedules
   `InlineCIDAttachmentPrefetcher` after the ingest context saves. The eager
   prefetcher downloads missing inline attachments through the existing
   `AttachmentDownloader` path.

### Chat Display Flow

1. `ChatMessageRowModel` snapshots Core Data state for SwiftUI.
2. `MessageBubble` asks `MessageBubbleLoader` for sender info, rich-content
   classification, shared-document links, forwarded-display content, and HTML
   analysis.
3. For normal personal bubbles, persisted `Message.chatPreviewText` wins and is
   passed through `MessageContentView.textBubble`. Runtime text cleanup is used
   only when the stored preview is nil or blank.
4. `MessageDisplayPolicy.shouldShowHTMLPreview` routes rich HTML to
   `EmailContentSection`.
5. `EmailContentSection` calls `EmailPreviewPipeline`, which loads a canonical
   `EmailPreviewSource`, classifies it, and returns one of:
   `calendarInvite`, `netlifyDeploy`, `newsletter`, `transactional`, or `html`.
6. Native preview cards render the structured routes. The `.html` route renders
   through `EmailPreviewSnapshotView`, with `MiniEmailWebView` only after snapshot
   rendering fails.

### Full Original Email Flow

1. `HTMLMessageView` calls
   `OriginalEmailSourceLoader.loadOriginalEmailSourceToCompletion`.
2. `CanonicalEmailContentLoader` resolves sources in order: per-message HTML
   file, `bodyStorageURI`, raw-source embedded HTML, recovered HTML, then
   plain text when no usable HTML exists.
3. `HTMLContentLoader.prepareOriginalHTML` sanitizes and wraps the original HTML
   for `.original` display. Remote attachment-style image fallbacks use cached
   rewrites immediately and warm missing rewrites out of band.
4. `OriginalEmailSourceLoader` stores wrapped original HTML in
   `RenderedMessageCache`.
5. `HTMLMessageView` renders HTML through `HTMLWebView` /
   `BaseEmailWebView(.fullInteractive)`. Native plain text is used only when
   there is no usable HTML or recovery cannot produce one.

### DOM Parsing

- `EmailDocument` hides SwiftSoup and exposes stable value facts such as
  paragraph-aware text, preview text, HTML summary, metrics, render-quality facts,
  and normalized inline content IDs.
- `ParsedEmailProvider` caches immutable `ParsedEmail` objects by
  `messageId + sourceSignature`.
- Shared parsed facts are used by preview source extraction/classification,
  bubble inline-CID analysis, and render-quality evaluation.
- Mutating passes still own their local work: sanitizer URL/CSS/tracking cleanup,
  display-wrapper insertion, raw-source recovery, and plain-text-only cleanup.

### Snapshot Previews

- `EmailPreviewPipeline` produces an `HTMLPreviewPayload` for rich HTML that does
  not fit a native preview card.
- `EmailPreviewSnapshotViewModel` builds a snapshot cache key from the preview
  source key, rendered HTML fingerprint, rounded container width, dark-mode
  state, and renderer version.
- `EmailPreviewSnapshotCache` owns disk image bytes and metadata.
- `EmailPreviewSnapshotRenderer` renders in an offscreen `WKWebView`, measures
  height, snapshots a `UIImage`, and stores it on disk.
- `RenderedMessageCache` records only lightweight snapshot metadata. It does not
  own snapshot image bytes.
- Snapshot failure is the only normal path to `MiniEmailWebView`.

### Inline Attachment Flow

- Ingest records known inline CID targets.
- `InlineCIDAttachmentPrefetcher` tries to download missing inline attachments
  after persistence succeeds.
- `BaseEmailWebView` registers `CIDSchemeHandler` for the custom `cid:` scheme.
- `CIDSchemeHandler` first serves local files. If a local file is missing, it
  performs an on-demand Gmail attachment fetch and persists the file. If that
  also fails, it returns a transparent pixel instead of a broken image.

## Cache Ownership

| Owner | Scope | Notes |
|---|---|---|
| `HTMLContentHandler` | Disk owner for stored per-message HTML files | Canonical source for saved HTML bodies. |
| `ParsedEmailProvider` | In-memory parsed DOM facts | Read-only facts keyed by `messageId + sourceSignature`; not a render artifact cache. |
| `RenderedMessageCache` | In-memory derived render artifacts | Preview source, render model, wrapped HTML, bubble analysis, rich-content classification, legacy fallback text, and snapshot metadata. |
| `EmailPreviewSnapshotCache` | Disk snapshot images and metadata | Owns image bytes; invalidated by cache key inputs and age. |
| `HTMLContentLoader.htmlCache` | Low-level `HTMLLoadResult` variants | Retained for legacy/fallback loader APIs until those producers can be narrowed. |
| `ProcessedTextCache` | Legacy text fallback and prefetch compatibility | Normal bubbles should not depend on it when `chatPreviewText` exists. |
| `MessageBubbleHTMLAnalysisCache` | Small compatibility shim | Mirrors analysis also stored in `RenderedMessageCache`; retained for low-churn tests/call sites. |
| `HTMLRemoteImageAttachmentFallback` | Remote image rewrite cache/warmup | Keeps original and preview rendering from blocking on attachment-style remote image rewrites. |

## Fallback Policy

- Stored `Message.chatPreviewText` is the canonical visible text source for
  normal personal chat bubbles.
- HTML-backed old records with missing stored preview text may derive
  compatibility text through DOM-backed HTML extraction.
- True plain-text-only messages and old blank-preview records may use
  `PlainTextQuoteRemover` / `PlainTextSignatureRemover`.
- Forwarded lead-in parsing remains separate so forwarded cards keep their
  structured behavior.
- Rich HTML chat previews use native cards first, then cached snapshots. Live
  `MiniEmailWebView` is fallback-only.
- Full original email rendering prefers full HTML fidelity. Preview-specific
  scaling or snapshot transforms must not enter the original-email path.
- Original email renders in a light WebView trait environment to preserve
  authored colors. Preview and snapshot rendering follow app appearance while
  preserving authored colors where possible.
- Inline CID eager fetch is best effort. The `CIDSchemeHandler` on-demand path is
  retained as the required display fallback.
- Regex fallback in dangerous-markup sanitization and raw `cid:` scanning remains
  parse-failure safety coverage, not the normal path.

## Cleanup Completed In This Closeout

Deleted as obsolete and unused:

- `HTMLPreviewView` from `Views/Chat/HTMLMessageView.swift`
- `Views/Components/EmailContent/HTMLPreviewWebView.swift`
- `Services/HTMLSanitization/HTMLAttributedStringConverter.swift`
- `Services/HTMLSanitization/HTMLComplexityAnalyzer.swift`
- `Services/HTMLSanitization/HTMLSanitizerProtocol.swift`

Intentionally retained:

- `MiniEmailWebView`, because snapshot rendering still needs a failure fallback.
- `RegexSanitizer`, because CSS sanitizer and DOM parse-failure dangerous-markup
  cleanup still use it.
- `RawEmailSourceSanitizer`, because Gmail raw-source recovery remains a real
  compatibility path.
- `PlainTextQuoteRemover` and `PlainTextSignatureRemover`, because true
  plain-text-only and old blank-preview records still need cleanup.
- `ProcessedTextCache`, `HTMLContentLoader.htmlCache`, and
  `MessageBubbleHTMLAnalysisCache`, because they still back explicit legacy or
  low-level compatibility paths.

## Guardrail Coverage

The closeout pass keeps or adds tests for:

- snapshot success/cache-hit paths not entering `MiniEmailWebView` fallback
- long-tail rich HTML returning the snapshot-backed `.html` preview payload
- stored `Message.chatPreviewText` winning for normal chat bubbles
- migrated preview-source consumers using `ParsedEmailProvider`
- original email returning full HTML when usable HTML exists
- eager inline CID prefetch plus `CIDSchemeHandler` on-demand fallback when eager
  fetch misses

## Validation Checklist

For rendering work, run:

```bash
./Scripts/codex-build.sh
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/EmailDOM'
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/HTMLSanitization'
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/Preview'
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/MessageBubbleLoaderTests' -only-testing 'esc-chatmailTests/MessageBubbleViewModelTests'
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/OriginalEmailSourceLoaderTests' -only-testing 'esc-chatmailTests/CIDSchemeHandlerTests' -only-testing 'esc-chatmailTests/InlineCIDAttachmentPrefetcherTests' -only-testing 'esc-chatmailTests/RenderedMessageCacheTests'
bash Scripts/run-tests.sh
```
