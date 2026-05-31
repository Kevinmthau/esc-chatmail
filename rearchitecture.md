# Rearchitecture: Email → Chat Bubble / HTML Transformation / Full Email Display

## Context

esc-chatmail renders Gmail messages as chat bubbles while preserving original-message fidelity. The three rendering surfaces under review are:

1. **Chat bubbles** — text-only bubbles for personal email; native preview cards for newsletters / transactional / calendar invites; scaled WebView fallback for "other rich HTML".
2. **HTML transformation pipeline** — sanitization, quote/signature stripping, dark-mode wrapping, CSS handling.
3. **Full original email viewer** — interactive WKWebView with inline-attachment (cid:) resolution.

The codebase is large and mature: ~65,000 LOC of app code + ~40,000 LOC of tests across 342 Swift files. The pipeline has been heavily iterated and shows strong defensive thinking (CSP injection, tracking-pixel removal, multi-source fallbacks, classification scoring, memory-pressure handling). But it has also accumulated significant complexity, much of it concentrated in regex-based HTML manipulation, and `AGENTS.md` itself flags several known-fragile paths.

This document identifies what's working, where the architecture is paying a complexity tax, and a prioritized set of improvements ranging from quick wins to a meaningful rearchitecture. It started as a decision document and now also records implementation status for shipped phases so remaining work can be planned from the current architecture.

---

## Architecture Snapshot

### Ingestion pipeline (Gmail API → Core Data)

```
GmailMessage
   ↓ MessageProcessor.processGmailMessage           (Services/MessageProcessor.swift:1)
   ↓   – extractHeaders                              (line 300)
   ↓   – extractContent (recursive MIME traversal)   (line 371)
   ↓   – fetchLargeBodyContent for >25KB parts       (line 510)
   ↓   – createCleanedSnippet                        (line 633)
   ↓   – isNewsletterOrPromotion (40+ scored signals)(line 94)
   ↓   – extractAttachments + Content-ID dedup       (line 735)
   ↓   – canonicalContent                            (line 442)
ProcessedMessage  ──► MessagePersister (actor) ──► Core Data
                                                     │
                                            HTML body on disk (HTMLContentHandler)
                                            bodyStorageURI on Message
```

### Display pipeline (Core Data → SwiftUI)

```
Message (NSManagedObject)
   ↓ ChatMessageRowModel  (view-model snapshot)      (Services/Chat/ChatMessageRowModel.swift:101)
   ↓
MessageBubble (SwiftUI)                              (Views/Chat/MessageBubble.swift:5)
   ↓ MessageBubbleViewModel.loadIfNeeded
   ↓ MessageBubbleLoader (actor)                     (Services/Chat/MessageBubbleLoader.swift:564)
   ↓   – loadSenderInfo  (contacts resolution)
   ↓   – loadContent     (text + analysis + forwarded parse)
   ↓
MessageDisplayPolicy.shouldShowHTMLPreview           (Views/Chat/MessageDisplayPolicy.swift:11)
   │
   ├── false → MessageContentView.textBubble          (Views/Chat/MessageContentView.swift:110)
   │             primary: persisted Message.chatPreviewText
   │             compatibility: DOM HTML fallback or legacy plain-text-only cleanup
   │
   └── true  → EmailContentSection                    (Views/Components/EmailContent/EmailContentSection.swift:84)
                 EmailPreviewPipeline.loadPreview     (Services/Preview/EmailPreviewPipeline.swift:61)
                   ├── CalendarInvitePreviewCard
                   ├── NetlifyDeployPreviewCard
                   ├── NewsletterPreviewCard          (NewsletterPreviewBuilder: 1093 LOC)
                   ├── TransactionalPreviewCard       (TransactionalPreviewBuilder: 1519 LOC)
                   └── EmailPreviewSnapshotView (cached image snapshot; MiniEmailWebView fallback)
```

### Full email viewer

```
HTMLMessageView                                      (Views/Chat/HTMLMessageView.swift)
   ↓ OriginalEmailSourceLoader.loadOriginalEmailSourceToCompletion(Services/OriginalEmailSourceLoader.swift)
   ↓   CanonicalEmailContentLoader (5 source strategies: messageId file → storageURI →
   ↓     rawSourceHTML → recovered → plain-text fallback)
   ↓   EmailRenderQualityEvaluator (risk score → fall back to native plain text if HTML is junk)
   ↓     (Services/EmailRenderQualityEvaluator.swift:23)
   ↓   HTMLSanitizerService.sanitize
   ↓   HTMLDisplayWrapper.wrapHTMLForDisplay (DOCTYPE, CSP, viewport, fallback fonts)
   ↓
HTMLWebView / BaseEmailWebView(.fullInteractive)     (Views/Components/EmailContent/BaseEmailWebView.swift:1)
   – Custom cid: scheme via CIDSchemeHandler          (Services/CIDSchemeHandler.swift:1)
     • on-demand fetch + persist if local copy missing (line 155)
     • respondWithTransparentPixel on miss
```

---

## What's working well — keep

These are genuine strengths; recommendations below preserve them.

- **Multi-source HTML loading with deterministic fallback chain.** `HTMLContentLoader` tries 5 sources in order with caching and rejection tracking. Robust against partial/missing data. (`Services/HTMLContentLoader.swift:137`)
- **Risk-scored HTML → native-text fallback.** `EmailRenderQualityEvaluator` produces a per-classification risk score with thresholds tuned per email kind. Catches "marketing HTML with no real text" and renders it readably. (`Services/EmailRenderQualityEvaluator.swift:23`)
- **Native preview cards** instead of WebView for newsletters / transactional / calendar invites. Faster, accessible, dark-mode-correct.
- **Custom `cid:` scheme handler** with on-demand attachment fetch and transparent-pixel fallback — much better than the typical "broken image" experience.
- **Actor-based concurrency model.** `MessageBubbleLoader`, `ProcessedTextCache`, `MessagePersister` are actors; SwiftUI VMs are `@MainActor`. Background prefetch is cancellable.
- **Persisted chat-bubble text source.** `Message.chatPreviewText` is now populated by synced ingest, optimistic sends, and batch creation, which keeps normal personal-message bubbles off the legacy runtime text-precedence path.
- **WebKit prewarming** addresses the first-launch WKWebView cost.
- **Strong test coverage** of the rendering pipeline (HTMLSanitization/, TextProcessing/, Preview/ test suites — ~40K LOC of tests).
- **Memory-pressure cache eviction** wired through `MemoryWarningObserver`.

---

## Issues and improvement opportunities

Listed by category, with file:line anchors. Each item has a severity and a remediation pointer to a numbered recommendation below.

### A. Regex-based HTML manipulation is fragile and pervasive

**Severity: high.** **Remediation: #1 (DOM parser) is the keystone change.**

- `HTMLQuoteRemover` has ~50 hand-tuned regex patterns for quote/signature/footer detection across Gmail / Outlook / Apple Mail / mozilla / real-estate brokers. Nested `<div>` handling is done by ad-hoc depth counting on text. (`Services/TextProcessing/HTMLQuoteRemover.swift:15-105`, total 495 LOC)
- `HTMLSanitizerService` strips dangerous tags via regex `<tag…>…</tag>` patterns. Carefully-crafted HTML (unclosed tags, attribute injection, nested same-tag) can defeat regex sanitization. CSP is the real safety net, but the sanitizer is presented as the primary defense. (`Services/HTMLSanitizerService.swift:48`, `HTMLSanitization/CSSParser.swift` is 837 LOC of custom CSS regex parsing)
- `HTMLDisplayWrapper.wrapExistingDocument` injects styles by string-searching for `<head>` / `<html>` and inserting at the closing bracket — works for well-formed mail but is exactly the kind of code that breaks on edge cases. (`HTMLSanitization/HTMLDisplayWrapper.swift:80-150`)
- `TextProcessing.extractPlainText` does HTML→text via a series of regex replacements (br/p/div→newlines, then strip `<[^>]+>`). Tables/lists are flattened by regex. (`Services/TextProcessing/TextProcessing.swift:29-108`)
- `MessageBubbleHTMLAnalysisBuilder.extractReferencedContentIDs` linear-scans HTML for `cid:` substrings. (`Services/Chat/MessageBubbleLoader.swift` analysis builder section)

Across these files there are well over 2,000 LOC of regex/string-manipulation HTML logic that would be a few hundred LOC against a proper DOM.

### B. The same HTML gets parsed multiple times per render

**Severity: high (perf and complexity).** **Remediation: #1 + #2.**

For a single chat-bubble render of one newsletter email, the HTML body is independently scanned:
1. By `HTMLContentLoader` to canonicalize.
2. By `HTMLSanitizerService.sanitize` (regex passes for tags, events, URLs, CSS, tracking).
3. By `HTMLDisplayWrapper.wrapHTMLForDisplay` (head injection by regex).
4. By `EmailRenderQualityEvaluator` (tag counts, regex matches, text extraction).
5. By `EmailPreviewClassifier` (signal scanning).
6. By `MessageBubbleHTMLAnalysisBuilder` (cid: extraction).
7. By `ChatBubbleTextProcessor` only for missing `Message.chatPreviewText`
   compatibility fallbacks.
8. By the relevant preview builder (newsletter or transactional, which scrape DOM structure).
9. By WKWebView (the actual final parse).

Most of these passes are O(n) over the body. For a 200KB marketing email that's a lot of avoidable work, much of it happening on view appear / scroll.

### C. The plain-text bubble pipeline is over-built

**Severity: medium.** **Remediation: #3.**

To produce the text shown in a personal-email chat bubble, content traverses:

`HTML → HTMLQuoteRemover (495 LOC) → TextProcessing.extractPlainText (408 LOC) → PlainTextQuoteRemover (491 LOC) → PlainTextSignatureRemover (845 LOC) → HTMLEntityDecoder (101 LOC) → rich-content classifier (in ProcessedTextCache, ~500 LOC of heuristics)`

That's ~2,800 LOC of cascading heuristics — partially redundant (quote removal happens in HTML *and* in plain text; entity decoding is duplicated; "Sent from my iPhone" is a target in both layers) — to produce a short string. This is also where the highest concentration of email-specific edge cases live, and where the test suite is largest. With DOM-based quote removal up-front the plain-text layer collapses to "extract text from the DOM."

Current status (2026-05-30): partially complete. Normal personal-message bubbles use persisted `Message.chatPreviewText` as the visible text source and no longer derive bubble text through the legacy runtime cascade. `MessageBubbleLoader` now enters fallback text processing only when `chatPreviewText` is nil/blank or when parsing a forwarded-message lead-in. HTML-backed missing-preview records derive compatibility text through the DOM-backed HTML path. The legacy plain-text quote/signature removers remain only behind named plain-text-only/old-record fallback helpers.

### D. `MiniEmailWebView` (scaled live WebView) in scrolling chat

**Severity: medium-high (UX fragility).** **Remediation: #4.**

`AGENTS.md` explicitly warns:

> "MiniEmailWebView height changes can destabilize scrolling. Keep preview heights predictable."
> "Avoid fragile solutions that depend on scaling full email HTML documents in scrolling lists."

This is the fallback used when no specialized preview card fits, which is a meaningful fraction of "long-tail" promotional email. Each instance:
- spins up a live WKWebView in a list cell
- loads + lays out arbitrary email HTML at fractional scale
- can change reported size after load, jolting scroll position

The native preview cards (newsletter, transactional, calendar, netlify) cover the well-classified cases. Anything that falls through is exactly the case where a live scaled WebView is most fragile.

### E. Loosely-coordinated caches

**Severity: medium.** **Remediation: #5.**

There were several caches with overlapping responsibilities:

| Cache | File | Keyed on |
|---|---|---|
| `HTMLContentLoader.htmlCache` (NSCache, 50MB) | `Services/HTMLContentLoader.swift:105` | messageId + variantKey (darkMode, cleanupMode, displayPurpose, ...) |
| `ProcessedTextCache` (LRU actor) | `Services/ProcessedTextCache.swift:164` | messageId + sourceSignature + previewMode + processingVersion |
| `MessageBubbleHTMLAnalysisCache` (NSCache, 512) | `Services/Chat/MessageBubbleLoader.swift:12` | (per-call composite key) |
| `EmailPreviewSourceLoader` source cache (NSCache) | `Services/Preview/EmailPreviewSourceLoader.swift` | messageId + sourceSignature + preview-mode metadata |
| `EmailPreviewSnapshotCache` (disk) | `Services/Preview/EmailPreviewSnapshotCache.swift` | preview cache key + rendered HTML fingerprint + width + dark mode |

Invalidation involves recomputing `htmlSourceSignature(messageId:bodyStorageURI:)` at many call sites and threading it through composite cache keys. #7 removed the per-body text-field SHA256 work from `MessageBubble`, but the broader cache story still has several independently-derived signatures that need to agree.

Current status (2026-05-30): partially complete. `RenderedMessageCache` now owns derived render artifacts keyed by `(messageId, sourceSignature)` with per-artifact variant keys. `EmailPreviewSourceLoader` no longer has its own in-memory source cache; preview source extraction/classification now coalesces through the render cache. `EmailPreviewPipeline` uses the render cache for preview render models and wrapped preview HTML. `MessageBubbleLoader` reads/writes render-cache analysis, rich-content classification, and legacy fallback text while retaining compatibility with `ProcessedTextCache`. `OriginalEmailSourceLoader` reuses lazy wrapped original HTML through the render cache. `EmailPreviewSnapshotCache` remains the disk owner for images; only lightweight snapshot metadata is recorded in the render cache.

### F. Snippet representations are fragmented

**Severity: low-medium.** **Remediation: #6.**

For a single message the system maintains:
- `gmailMessage.snippet` (from Gmail API)
- `Message.snippet` (persisted)
- `Message.cleanedSnippet` (persisted, post-processing, conversation-list oriented)
- `Message.chatPreviewText` (persisted canonical chat-bubble text)
- `fullTextContent` (loaded async at view time, now normally the stored chat preview or a legacy processed fallback)

Current status (2026-05-29): recommendation #6 is complete. `Message.chatPreviewText` is the canonical personal-message chat bubble source, optimistic outgoing messages populate it from the composed body, and batch-created messages map `ProcessedMessage.chatPreviewText`. `MessageBubbleLoader` skips the outgoing-body "richness" comparison whenever stored preview text exists. Older records with nil or blank `chatPreviewText` still fall back to processed loaded text, and outgoing legacy records can still use the body-vs-loaded-text comparison for compatibility.

### G. `MessageBubble.loadSignature` did SHA256 work per body eval

**Severity: low (perf nit).** **Remediation: #7, complete.**

Original issue: every SwiftUI body re-evaluation computed `loadSignature`, which called `contentFingerprint` (SHA256) on ~10 string fields and joined them. SwiftUI re-evaluates bodies aggressively, so this was many SHA256 hashes per scroll tick.

Current status (2026-05-29): complete. `ChatMessageRowModel` now precomputes the string fingerprints in `MessageBubbleLoadSignatureComponents`; `MessageBubble.loadSignature` only combines those fingerprints with the current HTML source signature and contact refresh token.

### H. `prepareOriginalHTML` and `preparePreviewHTML` share a lot

**Severity: low.** **Remediation: #5 (cache unification) covers this.**

Two parallel pipelines through `HTMLContentLoader` with subtly different parameters (`displayPurpose`, `originalHTMLPreference`, `cleanupMode`). The variantKey enumerates the product of these. Easy to add a new variant by mistake; not easy to reason about cache pressure.

### I. `CIDSchemeHandler` does on-demand network fetch from the WebView thread

**Severity: low.** **Remediation: #8.**

If an inline-image attachment isn't on disk at render time, the scheme handler synchronously triggers a Gmail API fetch + disk write, then responds (`Services/CIDSchemeHandler.swift:155-204`). This is correct behavior but can cause perceptible flicker on first open of older messages. Inline attachments are deterministically known at ingest; they could be eagerly downloaded then.

### J. Dark-mode policy is implicit

**Severity: low (docs).** **Remediation: #9.**

`HTMLDisplayWrapper.theme` returns light-on-light for `.original` regardless of `isDarkMode` — a deliberate choice to preserve authored colors — but it's not documented in the type and surprises on first read. The preview path *does* honor dark mode, plus a "fallback dark text" CSS override that intentionally avoids overriding emails that already specify colors. The intent is correct; the policy deserves to be named.

---

## Recommendations (prioritized)

### 1. **Adopt a proper HTML DOM parser** (keystone — unlocks 2, 3, 7)

**Effort: large (1–2 weeks).** **Impact: very high.**

Adopt SwiftSoup (pure Swift, MIT-licensed, well-maintained, no Obj-C bridge needed) as the canonical HTML representation. Parse the canonical HTML *once*, then expose a typed DOM to all downstream consumers.

- `EmailDocument` type wraps the parsed `Document` plus a few derived structures (referenced cid: set, image count, table count, link count, head/body separation).
- Sanitization becomes a typed `Whitelist`-based traversal (SwiftSoup ships an API for this) instead of regex tag-stripping. Replaces `HTMLSanitizerService` and most of `HTMLSanitization/*`.
- Quote/signature removal becomes a DOM walk that finds `div.gmail_quote`, `blockquote[type=cite]`, `#mail-editor-reference-message-container`, etc. by selector, and removes their subtrees. Replaces `HTMLQuoteRemover` (495 LOC → ~50).
- `extractPlainText` becomes `document.text()` (SwiftSoup gives a sensible default), with a thin wrapper to preserve paragraph breaks. Replaces `TextProcessing.extractPlainText`.
- `cid:` enumeration becomes `document.select("img[src^=cid:]")`. Replaces the linear-scan extractor.
- Style/CSS injection (display wrapper) becomes node insertion, not string surgery.

What this **doesn't** replace: `HTMLURLSanitizer` (still want URL-level sanitization), `HTMLTrackingRemover` (pattern-based pixel detection is fine), and the inline `style=""` CSS sanitization (CSSParser is doing real work — but it can run against parsed attributes instead of the document).

Files most affected (rewrite or thin):
- `Services/HTMLSanitizerService.swift`
- `Services/HTMLSanitization/HTMLDisplayWrapper.swift`
- `Services/HTMLSanitization/CSSParser.swift` (keep, target inline attributes only)
- `Services/TextProcessing/HTMLQuoteRemover.swift` (replace)
- `Services/TextProcessing/TextProcessing.swift` (collapse to a thin wrapper)
- `Services/EmailRenderQualityEvaluator.swift` (counts become DOM queries)
- `Services/Preview/NewsletterPreviewBuilder.swift` and `TransactionalPreviewBuilder.swift` (use DOM accessors)

Risk: SwiftSoup's parser is more permissive than ours in some edge cases; it can introduce visible diffs if future call sites switch from string processing to DOM processing without fixture coverage. Mitigation for new migrations: golden-master test against the existing TextProcessing/HTMLSanitization fixtures before removing any remaining fallback path.

### 2. **Single canonical "ParsedEmail" pass per message**

**Effort: medium (now unblocked by #1).** **Impact: high (perf).**

Once a DOM parser is in place, parse each message *once* into an `EmailDocument` and pass it (not the raw String) to all consumers: sanitizer, classifier, quality evaluator, preview builders, analysis builder.

Cache on `messageId + sourceSignature`. The single canonical pass replaces the ~7 redundant scans listed in §B.

Current status (2026-05-30): partially complete. A small `ParsedEmail` abstraction and `ParsedEmailProvider` actor now cache immutable facts by `messageId + sourceSignature`, prune stale entries when a message's source signature changes, and emit low-noise `html-preview` diagnostics for cache hit/miss duration and parse failures.

Consumers now sharing `ParsedEmail`:
- `EmailPreviewSourceLoader` uses it for preview HTML text, HTML summary, and `EmailPreviewClassifier` inputs.
- `EmailPreviewClassifier` uses `ParsedEmail`'s centralized classification metrics/text fallback when available.
- `MessageBubbleHTMLAnalysisBuilder` uses it for original inline `cid:` extraction while preserving raw fallback extraction on parse failure.
- `EmailRenderQualityEvaluator` can evaluate from `ParsedEmail` render-quality facts; `HTMLContentLoader` uses that path for automatic original-view quality fallback on sanitized display HTML.

Consumers still parsing or scanning independently, by design:
- `HTMLSanitizerService` still performs DOM dangerous-markup removal plus specialized URL, tracking-pixel, and CSS sanitization because these are mutating safety passes, not reusable read-only facts.
- `HTMLDisplayWrapper` still parses during full-document head injection and retains string injection as the parse-failure fallback.
- `EmailPreviewImageExtractor` still sanitizes before image selection so unsafe/tracking image behavior remains unchanged.
- Direct `NewsletterPreviewBuilder` / `TransactionalPreviewBuilder` raw-HTML entry points keep their local extraction path for tests and compatibility; the production `EmailPreviewSource` path receives shared extracted facts.
- `HTMLQuoteRemover`, `TextProcessing`, and plain-text-only fallback paths remain independent where they intentionally transform or recover content.

Next phase: do **not** build the unified `RenderedMessageCache` yet. Let parsed-email sharing stabilize first, then use it as the input layer for #5.

### 3. **Collapse the plain-text pipeline to a single DOM-based extraction**

**Effort: medium (now unblocked by #1 and #6).** **Impact: high (removes ~2000 LOC of edge-case heuristics).**

With the DOM-level quote/signature stripping from #1, the chat-bubble text extraction becomes:

```
EmailDocument
  → stripQuotedSubtrees + stripSignatureSubtrees   (DOM walks)
  → extractPlainText                                (single pass)
  → entity decode is no longer needed (DOM holds decoded text)
```

`PlainTextQuoteRemover` (491 LOC) and `PlainTextSignatureRemover` (845 LOC) become a fallback used only for emails that arrive as plain-text (no HTML available). Most of the regex churn is retired.

Tests will need updating but the existing fixtures are excellent regression coverage.

Current status (2026-05-30): partially complete. The normal render path is now:

```
Message.chatPreviewText
  -> MessageBubbleLoader.fullTextContent
  -> MessageContentView.textBubble
```

The remaining text-processing paths are intentionally narrow:
- HTML-backed records with nil/blank `chatPreviewText` use `loadCompatibilityContent`, which derives text from stored/recovered HTML through `ChatBubbleTextProcessor.htmlCompatibilityFallback` and the DOM-backed `TextProcessing.extractPlainText`.
- True plain-text-only records and old records with no stored preview use `ChatBubbleTextProcessor.plainTextOnlyFallback` / `legacyAutoDetectedFallback`, which is the only remaining production path into `PlainTextQuoteRemover` and `PlainTextSignatureRemover`.
- Outgoing records created before optimistic sends populated `chatPreviewText` may still use `LegacyOutgoingBodyTextFallback` to prefer the composed body over a truncated stored HTML/snippet fallback.
- Forwarded messages still parse lead-in text through `ForwardedMessageDisplayParser`; structured forwarded-card behavior is unchanged.
- `ProcessedTextCache` still stores compatibility fallback text for old records, plus a separate rich-content analysis mode for stored-preview records so rich preview routing can work without deriving visible bubble text.

Next recommended phase: **#2, single canonical parsed-email pass**. Do not start a unified `RenderedMessageCache` until one parsed representation can feed sanitizer, classification, analysis, preview builders, and fallback text extraction.

### 4. **Replace `MiniEmailWebView` with rendered snapshots**

**Effort: medium (1 week).** **Impact: high (scroll stability).**

For "rich HTML that didn't fit a native card", render the HTML to an offscreen `WKWebView` *once* (during ingest, or lazily on first request), `snapshot` the result to a `UIImage`, and show the image in the chat bubble. The image is:
- correctly sized (fixed height — solves AGENTS.md's scroll-stability concern)
- cheap to display (no live WebView in scroll cells)
- still tappable to open the live `HTMLMessageView`
- cacheable on disk by content signature

The snapshot is produced once per message per dark-mode-state and stored under Caches/. Memory pressure clears them; signatures regenerate them.

This is the biggest UX-stability win in the list and the most independent: it can ship without #1.

Current status (2026-05-28): the snapshot rendering path is the default rich
HTML preview path and still falls back to live `MiniEmailWebView` rendering if
snapshot generation fails. Earlier automated validation covered the snapshot
cache/renderer, preview scale calculation, message display policy, and a
standalone Debug build on iPhone 17 Pro. This flag removal reran the snapshot
cache/renderer suite. The local
simulator smoke covered unauthenticated launch and an empty authenticated
UI-test shell; it did not cover scroll stability across a mixed real/seeded
rich-thread mailbox because no mailbox data was available on the simulator.

#### Rendering stabilization checklist

Stable means:
- Rich HTML chat previews enter through `EmailPreviewSnapshotView`; live `MiniEmailWebView` is only the snapshot-failure fallback or an explicitly test/debug-only surface.
- Snapshot cache keys vary by preview source signature, rendered HTML fingerprint, rounded container width, dark-mode state, and renderer version.
- A successful snapshot render writes a disk-cache entry and updates the visible preview only while the current load task is still active.
- Cancellation or a newer load identity must not update stale image, height, cache-key, or fallback state.
- Full-message rendering remains on `HTMLMessageView` / `BaseEmailWebView(.fullInteractive)` and does not consume preview-only snapshot transforms.

Metrics/logs to inspect with `ESC_LOG_DIAGNOSTICS=html-preview`:
- `EmailPreviewSnapshot event=cache-hit` / `cache-miss` counts and `cacheKeyHash`.
- `event=render-success` count, `duration`, `height`, and `cacheStored`.
- `event=render-failure` count, `reason`, `duration`, and cumulative `timeouts`.
- `event=fallback-mini-webview` count. This should be rare in normal scrolling; repeated counts on the same message indicate a snapshot-rendering bug or unsupported HTML case.
- Existing `EmailPreviewPipeline` / `EmailPreviewSourceLoader` diagnostics for source kind, classification, and fallback preview source.

Manual QA recipe:
- Use a real mailbox thread on iPhone 17 Pro with mixed messages: newsletters, transactional emails, forwarded messages, calendar invites, inline `cid:` images, remote images, malformed HTML, and long replies.
- Open the thread in light and dark mode, scroll rapidly through the rich previews, then pause on each preview and confirm there are no late height jumps after images or snapshots settle.
- Tap each preview into the full original email and verify the full-message view preserves fidelity independently of the chat preview.
- Repeat after clearing Caches/ or installing fresh so first-render misses, subsequent cache hits, remote-image warmup reloads, and failure fallback behavior are all visible in diagnostics.
- Capture the diagnostic counts before and after the run; cache hits should rise on the second pass, render failures/timeouts/fallbacks should stay low, and no message should repeatedly fall back without a clear reason.

Next large refactor: **#2, single canonical parsed-email pass**. Keep snapshot
preview architecture stable while moving duplicated parsing/classification work
behind one parsed representation.

### 5. **Unify rendering caches behind a single coordinator**

**Effort: medium.** **Impact: medium (clarity > raw perf).**

Current status (2026-05-30): partially complete. `RenderedMessageCache` is now an actor keyed on `(messageId, sourceSignature)` with per-artifact variant keys for inputs that legitimately change by dark mode, cleanup mode, sender/subject metadata, attachment fingerprints, or preview route. It supports lazy/partial population, source-signature pruning, memory-warning clearing, LRU-ish capacity limits, and in-flight coalescing.

The shipped value is `RenderedMessageArtifacts`:

```swift
struct RenderedMessageArtifacts {
    let sourceSignature: String
    var canonicalPlainText: String?
    var chatBubbleTextByVariant: [RenderedMessageVariantKey: RenderedMessageChatBubbleText]
    var htmlAnalysisByVariant: [RenderedMessageVariantKey: MessageBubbleHTMLAnalysis]
    var richContentClassificationByVariant: [RenderedMessageVariantKey: Bool]
    var previewSourceByVariant: [RenderedMessageVariantKey: EmailPreviewSource]
    var previewRenderModelByVariant: [RenderedMessageVariantKey: EmailPreviewRenderModel]
    var wrappedPreviewHTMLByVariant: [RenderedMessageVariantKey: HTMLPreviewPayload]
    var wrappedOriginalHTMLByVariant: [RenderedMessageVariantKey: String]
    var snapshotMetadataByVariant: [RenderedMessageVariantKey: RenderedMessageSnapshotMetadata]
}
```

Ownership after this change:
- `RenderedMessageCache`: in-memory derived render facts, preview source/classification, preview render models, wrapped preview/original HTML, bubble analysis, rich-content flags, legacy fallback text, snapshot metadata.
- `ParsedEmailProvider`: shared DOM-derived immutable parse facts; it remains the input layer, not the render artifact owner.
- `EmailPreviewSnapshotCache`: disk-backed snapshot image bytes and metadata files. It is intentionally not replaced.
- `HTMLContentLoader.htmlCache`: still caches low-level wrapped `HTMLLoadResult` variants used by legacy/fallback load paths; it remains until `HTMLContentLoader` itself can become a producer behind `RenderedMessageCache`.
- `ProcessedTextCache`: still stores compatibility text results for old records and chat prefetch callers; `MessageBubbleLoader` now mirrors useful results into `RenderedMessageCache`.
- `MessageBubbleHTMLAnalysisCache`: retained as a small compatibility shim for tests and low-churn call sites; `MessageBubbleLoader` writes through to the render cache.

Remaining cleanup:
- Move any remaining direct `HTMLContentLoader.htmlCache` wrapped-result ownership behind `RenderedMessageCache` when the low-level loader API can be narrowed without behavior changes.
- Retire `MessageBubbleHTMLAnalysisCache` after downstream tests and call sites no longer need a dedicated shim.
- Narrow `ProcessedTextCache` to legacy/prefetch-only use, or fold its remaining fallback text path fully into `RenderedMessageCache`.
- Keep snapshot image bytes disk-backed; do not store rendered images in memory artifacts.

### 6. **Pick one canonical preview text per message at ingest**

**Effort: small.** **Impact: medium.**

Compute the final "chat bubble preview text" at ingest time (in `MessageProcessor` or right after), store it in a single new field on `Message`, and use it everywhere. The shipped version keeps the runtime `LegacyOutgoingBodyTextFallback` comparison only for legacy outgoing records that do not have stored preview text.

#1 is now in place for migrated HTML paths, so follow-up #3 can simplify the remaining fallback text extraction without changing the primary chat-bubble source.

Current status (2026-05-29): complete. Synced Gmail messages already populate `Message.chatPreviewText`; this phase filled the remaining creation paths and simplified the read path.

Files touched:
- `Services/Send/GmailSendService+OptimisticUpdates.swift` — optimistic messages set `chatPreviewText` from the full composed body, preserving paragraph breaks.
- `Services/CoreDataBatchOperations.swift` — batch-created messages map `ProcessedMessage.chatPreviewText`.
- `Services/Chat/MessageBubbleLoader.swift` — forwarded lead-in behavior remains special; otherwise stored chat preview wins, with processed loaded text only as the legacy fallback.
- `Views/Chat/MessageContentView.swift` — removed stale runtime text-processing helper surface.
- Tests: `MessageBubbleLoaderTests`, `MessageBubbleViewModelTests`, `GmailSendServiceOptimisticCreationTests`.

Validation completed on 2026-05-29:
- `./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/MessageProcessorTests' -only-testing 'esc-chatmailTests/MessageBubbleLoaderTests' -only-testing 'esc-chatmailTests/MessageBubbleViewModelTests' -only-testing 'esc-chatmailTests/ChatMessageRowModelTests' -only-testing 'esc-chatmailTests/GmailSendServiceOptimisticCreationTests'`
- `./Scripts/codex-build.sh`

### 7. **Memoize `MessageBubble.loadSignature`**

**Effort: tiny.** **Impact: small but real (frame-time during scroll).**

Move the signature computation off the body path.

Current status (2026-05-29): complete. `ChatMessageRowModel` constructs `MessageBubbleLoadSignatureComponents` with precomputed fingerprints for body text, chat preview text, snippets, and sender fields. `MessageBubble.loadSignature` still incorporates the current HTML source signature and contact refresh token, but no longer performs the text-field SHA256 work on each body evaluation.

### 8. **Eagerly fetch inline attachments at ingest**

**Effort: small.** **Impact: medium (first-open flicker).**

`MessageProcessor` already knows the set of `cid:`-referenced attachment IDs. Schedule them for download in the background sync queue at ingest, the same way other attachments are queued. The on-demand path in `CIDSchemeHandler` becomes a true fallback for retroactive cache loss instead of the common path for older messages.

Related shipped improvement (2026-05-29): original-email remote image fallback no longer blocks the initial full-message render on uncached attachment-style remote images. The original path now uses cached rewrites synchronously, warms missing image fallbacks out of band, and refreshes `HTMLMessageView` when the warmed result is available.

Current status (2026-05-31): complete. `MessageProcessor` now records normalized inline CID prefetch targets from both MIME `Content-ID` attachment metadata and DOM-backed HTML `cid:` references. `MessagePersister` registers those targets with `InlineCIDAttachmentPrefetchScheduler` on the ingest context; after that context saves, `InlineCIDAttachmentPrefetcher` refetches the saved message/attachment rows and delegates missing inline attachment downloads to the existing `AttachmentDownloader` path. The eager path dedupes by message id + normalized CID / attachment id, skips already cached local files, and logs missing attachment metadata without blocking message persistence.

`CIDSchemeHandler` remains the fallback for cases where eager fetch did not run, failed, found missing metadata, or local attachment files were later cleared. Its diagnostics now distinguish local/eager hits from on-demand fallback fetches.

### 9. **Document the dark-mode policy on `HTMLDisplayWrapper.Theme`**

**Effort: trivial.** **Impact: prevents future regressions.**

Add a doc comment to `HTMLDisplayWrapper.theme(...)` explaining:
- previews honor dark mode, with a fallback CSS that only re-colors text when the email didn't specify colors
- original-email view deliberately renders in light theme regardless of system dark mode, to preserve author intent

Document the same decision in `BaseEmailWebView.makeUIView` where `overrideUserInterfaceStyle = .light` is set for full-message mode.

### 10. **(Optional) Server-side preprocessing**

**Effort: very large.** **Impact: changes the shape of the problem.**

Out of scope for this review, but worth flagging: a serverless function that does the canonical parse + classification + preview-card extraction *once*, then serves a compact JSON manifest to the client, would let the iOS app stop doing thousands of lines of CPU-heavy HTML work on every device. Defer until #2, #3, and #5 clarify the remaining local-client responsibilities.

---

## Suggested implementation order

Each step is independently shippable and reduces risk for the next.

Completed:
- **#1 (DOM parser adoption)** — complete for migrated paths as of 2026-05-28.
- **#2 (single canonical parse pass)** — partially complete as of 2026-05-30; preview source extraction/classification, bubble inline-cid analysis, and render-quality facts now share `ParsedEmail`, while mutating sanitizer/wrapper/image-selection paths remain independent.
- **#3 (collapse plain-text pipeline)** — partially complete as of 2026-05-30; normal bubbles no longer derive visible text through the legacy runtime cascade, while explicit legacy/plain-text-only fallbacks remain.
- **#4 (snapshot-based preview)** — default rich HTML preview path as of 2026-05-28.
- **#6 (canonical preview text at ingest)** — complete as of 2026-05-29.
- **#7 (memoize loadSignature)** — complete; text fingerprints are precomputed in `ChatMessageRowModel`.
- **#8 (eager inline attachment fetch)** — complete as of 2026-05-31; ingest records normalized MIME/HTML CID targets, schedules post-save eager downloads for missing inline attachments, and keeps `CIDSchemeHandler` as on-demand fallback.

Remaining recommended order:
1. Continue hardening **#2 (single canonical parse pass)** only where low-risk consumers can use existing `ParsedEmail` facts without changing visible behavior.
2. **#5 cleanup** — remove compatibility cache shims once the new coordinator has soaked.
3. **#9 (document dark-mode policy)** — doc-only.

---

## Critical files for any of the above

- `esc-chatmail/Services/HTMLContentLoader.swift` (1268 LOC — central source-resolution + caching)
- `esc-chatmail/Services/HTMLSanitizerService.swift` and `esc-chatmail/Services/HTMLSanitization/*` (entire dir; sanitization + display wrap)
- `esc-chatmail/Services/TextProcessing/*` (HTMLQuoteRemover, PlainTextQuoteRemover, PlainTextSignatureRemover, TextProcessing, HTMLEntityDecoder)
- `esc-chatmail/Services/Preview/EmailPreviewPipeline.swift` + builders (Newsletter, Transactional, Calendar, Netlify)
- `esc-chatmail/Services/ProcessedTextCache.swift` (963 LOC)
- `esc-chatmail/Services/Chat/MessageBubbleLoader.swift` (1016 LOC)
- `esc-chatmail/Services/EmailRenderQualityEvaluator.swift`
- `esc-chatmail/Services/CIDSchemeHandler.swift`
- `esc-chatmail/Services/InlineCIDAttachmentPrefetcher.swift`
- `esc-chatmail/Views/Chat/MessageBubble.swift`, `MessageContentView.swift`, `MessageDisplayPolicy.swift`
- `esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift`, `EmailContentSection.swift`, `MiniEmailWebView.swift`

## Verification approach for any of the above

The repo already has the right harness. For each shipped change:

1. Build via `./Scripts/codex-build.sh`.
2. Run targeted suites first:
   - HTML / rendering: `HTMLContentLoaderTests`, `HTMLDisplayWrapperTests`, `HTMLSanitizerServiceTests`, `HTMLPreviewScaleCalculatorTests`, `HTMLMeaningfulContentCheckerTests`
   - Text processing: `HTMLQuoteRemoverTests`, `PlainTextQuoteRemoverTests`, `RawEmailSourceSanitizerTests`, `ForwardedMessageDisplayParserTests`
   - Preview classification/cards: `NewsletterPreviewBuilderTests`, `TransactionalPreviewBuilderTests`, `EmailPreviewClassifierTests`, `CalendarInvitePreviewBuilderTests`
   - Bubble loading: `MessageBubbleLoaderTests`, `MessageBubbleViewModelTests`, `MessageDisplayPolicyTests`
3. Run the full test suite via `bash Scripts/run-tests.sh`.
4. For #1 / #2 / #3 / #4: golden-master diff the rendered HTML/text for a corpus of representative messages with both pipelines enabled. Existing tests give excellent coverage of the "weird email" long-tail.
5. Manual UI verification in the iPhone 17 Pro simulator with a real inbox: scroll through a chat thread containing newsletters, transactional emails, forwarded threads, calendar invites, and inline-image messages. Tap into the full-message viewer on each.

---

## Bottom line

The current architecture is **functionally correct and impressively thorough**, and the biggest completed wins are now in place: DOM-backed HTML processing for migrated paths (#1), shared parsed-email facts for selected high-value consumers (#2 partial), snapshot-based rich previews (#4), persisted chat-preview text (#6), precomputed bubble signature fingerprints (#7), and eager inline CID attachment fetching (#8). The remaining complexity tax is concentrated in legacy/fallback plain-text processing and mutating rendering passes that still own their own parse/scans.

---

## Implementation status — recommendation #1

Current status (2026-05-28): the DOM rollout is complete for the migrated
processing paths. Quote removal, HTML text extraction, inline `cid:` enumeration,
preview extraction, and dangerous-element/event-handler sanitization now use the
DOM path unconditionally. The `EmailDOM_*` rollback flags and preview regex
fallback helpers have been removed. Snapshot-based rich HTML previews remain the
default path, and the live `MiniEmailWebView` fallback remains available when
snapshot rendering fails. The sanitizer pipeline still runs the specialized URL,
tracking-pixel, and CSS sanitizers after the DOM first pass.

Initial foundation landed on branch `claude/email-chat-architecture-EddMs`.

### What's in:

1. **SwiftSoup added as Swift Package dependency** (`esc-chatmail.xcodeproj/project.pbxproj`). Pin: `https://github.com/scinfu/SwiftSoup.git`, minimum version `2.7.0`. `Package.resolved` is populated under the project workspace.

2. **DOM abstraction layer** (`esc-chatmail/Services/EmailDOM/`):
   - `EmailDocument.swift` — value-free reference type wrapping `SwiftSoup.Document`. Hides SwiftSoup from downstream callers. Exposes: `parse`, `tryParse`, `outerHTML`, `bodyInnerHTML`, `plainText(preserveParagraphs:)`, `referencedInlineContentIDs()`, `renderQualityMetrics(...)`, `hiddenPrimaryContentCount(...)`, `normalizedContentID()`.
   - `EmailDOMTextExtractor.swift` — single-pass DOM walker that emits paragraph-aware plain text. Replaces ~80 lines of cascading regex in `TextProcessing.extractPlainText`.
   - `EmailDOMQuoteRemover.swift` — DOM-based replacement for `HTMLQuoteRemover.removeQuotes(from:mode:)`. Removes Gmail / Apple Mail / Outlook / Mozilla quote containers by CSS selector, truncates at structural boundaries and text markers ("On ... wrote:", "-----Original Message-----"). Preserves the fragment-vs-document nature of the input so compose-time reply quoting still emits clean MIME parts.
   - `EmailDOMHTMLSanitizer.swift` — SwiftSoup-backed dangerous-element and event-handler removal that preserves fragment/document shape before the existing URL, tracking-pixel, and CSS sanitizers run.

3. **Unconditional DOM delegation** wired into the migrated call sites:
   - `HTMLQuoteRemover.removeQuotes(from:mode:)` — delegates to `EmailDOMQuoteRemover`.
   - `TextProcessing.extractPlainText(from:)` — delegates HTML input to `EmailDocument.plainText`, with a small malformed-HTML recovery path for parser-empty edge cases.
   - `MessageBubbleHTMLAnalysisBuilder.extractReferencedContentIDs` — delegates to `EmailDocument.referencedInlineContentIDs`.
   - `HTMLSanitizerService` — delegates dangerous-element and event-handler removal to `EmailDOMHTMLSanitizer`, then continues through the existing specialized URL, tracking-pixel, and CSS sanitizers.
   - `EmailPreviewSourceLoader` / `EmailPreviewImageExtractor` — use SwiftSoup-backed preview extraction without legacy regex fallback helpers.

4. **DOM-backed infrastructure already migrated outside the rollout flags**:
   - `EmailRenderQualityEvaluator` uses `EmailDocument` for render-quality counts, visible text, spacer signals, footer ratios, and hidden primary-content detection.
   - `HTMLDisplayWrapper.wrapExistingDocument` inserts preview/display CSS through SwiftSoup and keeps the legacy string-injection path as a parse-failure fallback.

5. **Tests** (`esc-chatmailTests/EmailDOM/`):
   - `EmailDocumentTests.swift` — wrapper unit tests (parsing, plain-text extraction, cid: enumeration, normalization).
   - `EmailDOMQuoteRemoverTests.swift` — semantic tests covering Gmail / Apple Mail / Outlook patterns, structural truncation, text markers, signature mode, fragment-vs-document preservation, idempotence.
   - `EmailDOMHTMLSanitizerTests.swift` — DOM sanitizer and service-pipeline tests, including fragment preservation and post-DOM URL/tracking/CSS sanitizer coverage.
   - `EmailDOMPublicPathTests.swift` — public-path coverage proving quote removal, text extraction, inline `cid:` enumeration, and sanitizer routing use the DOM-backed paths.

6. **Validation completed on 2026-05-28**:
   - `./Scripts/codex-build.sh`
   - `./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/EmailDOM'`
   - `./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/HTMLSanitization'`
   - `./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/Preview'`
   - `./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/MessageBubbleLoaderTests' -only-testing 'esc-chatmailTests/MessageBubbleViewModelTests'`
   - `./Scripts/codex-test.sh`

### What's still to do (in priority order):

- **Next: continue #2 only for low-risk consumers** that can share existing `ParsedEmail` facts without changing rendering behavior.
- For render-cache cleanup, keep changes consumer-by-consumer and validate with `RenderedMessageCacheTests`, bubble loader/view-model tests, preview pipeline/builder tests, original source loader tests, and snapshot cache tests before broadening.

## Implementation status — original email recovery

Current status (2026-05-29): full original email loading now distinguishes slow recovery from true missing content. `HTMLMessageView` calls `OriginalEmailSourceLoader.loadOriginalEmailSourceToCompletion`, shows a "Recovering original email..." state after the initial wait, and only shows unavailable content when the completion load actually returns nil. When recovered HTML is saved to the per-message file, the view updates `bodyStorageURI` so later loads use the stable canonical source.

The same update made original-email remote-image fallback non-blocking for cached misses: `HTMLContentLoader.prepareOriginalHTML` uses cached attachment-style image rewrites immediately, starts a warmup task for pending rewrites, and `HTMLMessageView` reloads when `remoteImageAttachmentFallbackDidWarmNotification` fires for the message.
