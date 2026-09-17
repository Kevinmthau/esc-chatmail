# Cross-Cutting Consolidation Campaign

Last updated: 2026-07-06 (shipped: PRs #97-#104 + the ORG1/docs PR — see closeout notes)

Phase-3 follow-on to the service decomposition campaign (`decomposition.md`) and
the performance/reliability series (PR #94, `PR-DESCRIPTION.md`). Phase 2
eliminated single-type god objects; PR #94 fixed the measured hot spots. What
remains is **cross-cutting duplication** — the same logic maintained in two or
three places — plus a small set of organizational/groundwork items. This
campaign converges each duplicate onto one canonical implementation, one
concern per PR, behavior-preserving, anchored by characterization tests.

Item IDs use `CX` (consolidation) and `ORG` (organization/groundwork) prefixes
to avoid colliding with the perf plan's `M/U/CP/S/P/R/L/H/D/C` codes. Perf-plan
Phase C items (C1–C7, CP2) are **not** re-planned here; see
`PR-DESCRIPTION.md` for that backlog.

## Working method

Same as phase 2, with one addition for duplication work:

1. **Characterize first.** Lock observable behavior with tests against the
   existing public API before moving code. For a duplicated pair, run **both
   copies against the same shared fixture set** and record any divergence —
   divergence is a finding to surface, not something to silently normalize.
2. **Extract one concern per PR.** Introduce the canonical implementation,
   delegate from the originals. No behavior change.
3. **Keep the seam explicit.** Shared helpers are injected (initializer
   params / closures), not re-duplicated.
4. **Verify green** with the relevant `-only-testing` slice before moving on;
   full suite at each series end.

Per AGENTS.md: work on `main` unless asked otherwise; no commits without an
explicit request; smallest clean change per step.

## Sequencing

```
Warm-ups:      CX1 → CX2            (small, independent, build confidence)
Sync series:   CX3 → CX4            (CX3 lands first; CX4 consumes its classifier)
Pipeline:      CX5                  (independent; interacts with ORG2 — see note)
UI:            CX6                  (independent; guardrail area)
Caching:       CX7                  (independent; aligns with perf-plan C6 prereq)
Anytime:       ORG1 (file moves), ORG3 (strict-concurrency ratchet, step 1)
Independent:   ORG2 (ProcessedTextCache retirement — starts with investigation)
```

Dependency rules:
- **CX3 before CX4.** The extracted retry loop should consume the unified
  classifier, not the three legacy ones.
- **CX5 and ORG2 interact.** Deleting ProcessedTextCache (ORG2) removes one of
  CX5's three call sites. CX5 is worth doing regardless (it drops to two call
  sites); do not block it on ORG2.
- **ORG1 renames paths referenced by AGENTS.md and this doc** — include the
  doc updates in the same PR as each move batch.

## Status

| ID | Target | PRs | Status |
|---|---|---|---|
| CX1 | Attachment-display filter dedup | #97 | done |
| CX2 | TextProcessing shared primitives | #98 | done |
| CX3 | Error-classification consolidation | #99 | done |
| CX4 | Gmail retry-loop unification | #104 | done |
| CX5 | Meaningful-content fallback chain | #100 | done |
| CX6 | WebView coordinator core | #101 | done |
| CX7 | Cache invalidation contract + versioning | #102 | done |
| ORG1 | Directory/test-target organization | #105 | done |
| ORG2 | ProcessedTextCache retirement | — | investigation done; disposition recorded (implementation is its own series) |
| ORG3 | Strict-concurrency ratchet | #103 | step 1 done |

---

## CX1 — attachment-display filter dedup (S / low risk)

**Evidence.** `Message.displayableAttachments(using:hidingInlineReferencedInHTML:hidingCalendarInviteAttachments:)`
(`Services/Models/Message+Extensions.swift:177-220`) and
`ChatMessageRowModel.displayableAttachments(using:...)`
(`Services/Chat/ChatMessageRowModel.swift:280-323`) are the same algorithm
line-for-line — signature-image filter → non-displayable CID filter → sender
guard → referenced-CID filter → calendar-invite filter — differing only in
element type (`Attachment` vs `ChatMessageAttachmentModel`). Each type also
carries its own `deduplicatedAttachments` helper over the same dedup key.

**Plan.**
1. Characterize both copies against one shared fixture set (signature images,
   CID-referenced inline attachments, calendar invites, duplicates). Existing
   anchors: `MessageExtensionsTests`, `ChatMessageRowModelTests`,
   `AttachmentDownloaderTests`.
2. Introduce a small protocol (`contentId`, `isLikelySignatureImage`,
   `isCalendarInviteAttachment`, dedup key) + one generic filter function;
   both types delegate.

**Tests.** `-only-testing` slice: MessageExtensionsTests,
ChatMessageRowModelTests, AttachmentDownloaderTests, MessageBubbleLoaderTests.

## CX2 — TextProcessing shared primitives (S / low risk)

**Evidence.** `normalizeLineEndings` duplicated verbatim in
`Services/TextProcessing/PlainTextSignatureRemover.swift:889` and
`Services/TextProcessing/RawEmailSourceSanitizer.swift:87`. Email/URL/phone
regex definitions overlap across `PlainTextSignatureRemover.swift:114-175`,
`PlainTextQuoteRemover.swift:11-250`, and `RawEmailSourceSanitizer.swift`
(MIME/header constants).

**Plan.**
1. **Characterization gap:** `PlainTextSignatureRemover` has no dedicated
   suite (coverage is indirect via `ProcessedTextCacheTests`). Add one first,
   pinning current signature-detection behavior.
2. Extract `Services/TextProcessing/TextPatterns.swift` — namespaced enums
   (`EmailPatterns`, `URLPatterns`, `SignaturePatterns`, `MIMEPatterns`)
   holding the compiled regexes and constants; callers keep their matching
   logic and swap only the pattern definitions.
3. Extract shared line-ending normalization; delegate from both copies.

**Tests.** New PlainTextSignatureRemoverTests; existing
PlainTextQuoteRemoverTests, RawEmailSourceSanitizerTests,
ForwardedMessageDisplayParserTests, ProcessedTextCacheTests.

## CX3 — error-classification consolidation (M / medium risk)

**Evidence.** Three independent systems classify the same errors with
overlapping but non-identical criteria:
- `Services/Retry/RetryStrategy.swift:41-73` (`shouldRetry`, boolean)
- `Services/Background/BackgroundSyncErrorHandler.swift:15-112`
  (APIError → `BackgroundSyncRecoveryAction`)
- `Services/Sync/MessageFetcher.swift:51-89` (`isRetriableError`, its own
  URLError/NSError/APIError branches)

A new `APIError` case requires three coordinated edits. This is the M1 bug
class from the perf plan (History missing `credentialsRevoked`;
`invalidData` falling to `default → .retry`, inverting intent).

**Plan.**
1. Make the mapping canonical on the error type: `APIError.recoveryAction`
   (→ `BackgroundSyncRecoveryAction`), with retriability derived from it
   (`action != .abort && action != .abortNoRetry`).
2. `RetryStrategy.shouldRetry` and `MessageFetcher.isRetriableError` delegate
   to it; keep their URLError/NSError legs, but source APIError decisions
   from the single mapping. `BackgroundSyncErrorHandler` becomes a thin
   adapter (non-APIError inputs only).
3. Decide `Services/Retry/RetryExecutor.swift`'s fate in the same series: it
   is a complete retry framework used only by `AttachmentDownloader.swift:344`.
   Either adopt it as the shared loop's substrate in CX4 or delete it —
   don't leave a third path.
4. Divergences found during characterization (cases one classifier retries
   and another aborts) are surfaced in the PR description as explicit
   decisions, not silently unified.

**Tests.** GmailAPIClientHistoryErrorMappingTests, MessageFetcherTests,
BackgroundSyncManagerTests, BackgroundMessageProcessorTests,
AbandonedMessageRetryTests.

## CX4 — Gmail retry-loop unification (M / medium risk)

**Evidence.** `performRequestWithRetry` (`Services/API/GmailAPIClient.swift`) and
`performHistoryRequestWithRetry` (`Services/API/GmailAPIClient+History.swift`)
are near-identical retry engines: attempt accounting, once-only 401
refresh-grant (`allowedAttempts += 1`), cumulative-backoff circuit breaker,
Retry-After handling. The duplication has bitten twice: M1 was a parity bug
between the loops; M6 had to patch both in lockstep (including History's
missing final-attempt 429 guard).

**Plan.**
1. Extract one internal retry engine, parameterized by a status-code
   classification closure to preserve the intentional divergence
   (404 → `historyIdExpired` vs 404 → `notFound`); both public paths
   delegate.
2. Contracts that must survive unchanged (all pinned by existing tests):
   - `maxRetries` means **total attempts**, dynamically dispatched through
     the protocol witness (M2: MessageFetcher is the single retry owner and
     calls with `maxRetries: 1`).
   - Successful 401 refresh does not consume an attempt (M6), bounded by the
     once-only grant.
   - Non-idempotent sends (`allowsRetransmission: false`) never retransmit.
   - Retry-After is honored and capped; breaker backoff is recorded only for
     delays actually slept.

**Tests.** GmailAPIClientRetryAccountingTests, GmailAPIClientRetryBudgetTests,
GmailAPIClientRetransmissionTests, GmailAPIClientHistoryErrorMappingTests —
URLProtocol-level against the real client (mock-based tests are vacuous for
retry semantics). Sequences [401,200], [401,401], [500,500,500],
[401,500,200] must pass identically for message and history paths.

## CX5 — meaningful-content fallback chain (S–M / medium risk)

**Evidence.** The "quoted+signatures → quoted-only → original HTML"
degradation chain, each step guarded by
`HTMLMeaningfulContentChecker.hasMeaningfulContent`, exists in three copies:
- `Services/Caching/ProcessedTextCache.swift:1118-1131`
- `Services/HTMLContent/HTMLContentLoader+PlainTextHTML.swift:83-93`
- `Services/Chat/MessageBubbleHTMLAnalysisBuilder.swift:142-154`

PR #94's CP1b′ deliberately fixed footer wipeouts *upstream* to avoid touching
these copies; consolidating them removes that constraint for future work.

**Plan.**
1. Characterize the chain's behavior once (empty-after-cleanup input, content
   surviving only quoted-only mode, content surviving no mode) and confirm
   the three copies behave identically on the shared fixtures.
2. Extract a single helper (e.g.
   `HTMLCleanupFallback.cleanedHTML(from:modes:)`) encapsulating the ordered
   mode attempts + guards; all three sites delegate.
3. Mode *ordering* is uniform across the copies today — assert that in the
   characterization tests so future edits can't desynchronize a copy that no
   longer exists.

**Interaction.** ORG2 deletes the ProcessedTextCache copy; CX5 proceeds
regardless (see Sequencing).

**Tests.** ProcessedTextCacheTests, MessageBubbleLoaderTests,
HTMLContentLoaderTests, EmailDOMFooterRemovalTests (wipeout-guard adjacency).

## CX6 — WebView coordinator core (M / medium risk — guardrail area)

**Evidence.** `Views/Components/EmailContent/BaseEmailWebView.swift:84-252`
and `Views/Components/EmailContent/FullEmailReaderWebView.swift:91-361`
duplicate an identical eight-member coordinator suite: `LoadReadiness` enum,
`loadReadiness(windowPresent:width:height:)`, `logDeferredLoad`,
`recordLoadedSignature`, both `resetLoadedSignatureAfterFailure` overloads,
`reloadSignature`, `messageIdentitySignature`. Mode-specific signature inputs
differ (BaseEmailWebView's scaled-preview vs FullEmailReaderWebView's
inline-CID availability).

**Plan.**
1. Extract a shared load-readiness/reload-signature component with the
   mode-specific signature contributions injected (closure or small
   protocol); both coordinators compose it. Composition over inheritance —
   no new class hierarchy.
2. AGENTS.md flags this surface as delicate: behavior-preserving only, no
   functional change riders, and an on-device spot check (open full email;
   preview render; rotate/resize) in addition to the suites.

**Tests.** BaseEmailWebViewTests, FullEmailReaderWebViewTests,
FullEmailWebViewManagerTests, FullEmailReaderCoordinatorTests.

## CX7 — cache invalidation contract + versioning (M / medium risk)

**Evidence.** The three message-keyed caches each maintain their own
`messageID → cache keys` index with incompatible invalidation signatures:
- `Services/Caching/ProcessedTextCache.swift:1209` — `invalidate(messageId:) async`
- `Services/Caching/RenderedMessageCache.swift:483` —
  `invalidate(messageId:reason:) async`
- `Services/Caching/HTMLContentResultCache.swift:93` — `invalidate(messageId:)`,
  sync, NSLock-based while the other two are actors; its own header comment
  warns about the NSCache-write-inside-lock / `context.perform` interaction.

Version constants are inconsistent: ProcessedTextCache embeds
`processingVersion` in keys; the other two rely on source signatures. The
perf plan noted classifier unification (C6) requires a coordinated version
bump — impossible to do confidently while versioning is scattered.

**Plan.**
1. Define one `MessageKeyedCache` protocol: common
   `invalidate(messageId:reason:)` with a shared reason enum (reason unused
   by some caches is fine); route orchestration through the existing
   `CacheCoordinator` (phase-2 PR #54).
2. Consolidate version constants into `Services/Caching/CacheVersioning.swift`
   (`processingVersion`, sanitization/classification versions as needed);
   each cache embeds the relevant constant. This is the C6 prerequisite.
3. **Decision point, not a default:** converting `HTMLContentResultCache` to
   an actor would align it with the others but makes its API async — audit
   call sites (HTMLContentLoader paths) before committing; keeping it a
   locked class with the unified protocol is an acceptable outcome.

**Tests.** ProcessedTextCacheTests, RenderedMessageCacheTests,
CacheCoordinatorInvalidationPlanTests, HTMLContentLoaderTests.

## ORG1 — directory/test-target organization (S–M / low risk)

**Evidence.** 61 loose files at `esc-chatmail/Services/` root alongside 17
subdirectories (e.g. `ProcessedTextCache`, `RetryStrategy`, `GmailAPIClient`,
`HTMLContentLoader` at root while `Services/API/`, `Services/Caching/`
exist). 44 loose test files at the test-target root next to the `Sync/`,
`CoreData/`, `Caching/`, `TextProcessing/` subfolders PR #94 introduced.
`Conversations/` holds exactly one file (`ConversationIdentity.swift`).
`project.pbxproj` is `objectVersion 77` with filesystem-synchronized root
groups — moves are picked up automatically, no project-file edits.

**Plan.**
1. Move in small batches (one domain per PR), **pure moves only** — no code
   edits in the same commit, so review is a path diff.
2. Mirror source structure in the test target as part of each batch.
3. Fold `Conversations/` into the structure (either grow it into the
   conversation domain home or move its one file into `Services/Conversation/`
   and delete it).
4. Each batch updates path references in AGENTS.md ("Repo-Specific
   Priorities" names five exact paths), `decomposition.md`, and this doc.
5. Full suite green per batch; grep for hardcoded path strings
   (Scripts/, docs) before merging.

### ORG2 investigation outcome (2026-07-05)

**Backfill definition (recovered from `rearchitecture.md`, deleted in
`da93cb04`, item 3 "Collapse the plain-text pipeline"):** normal bubbles read
persisted `Message.chatPreviewText`; the plain-text pipeline (and the cache in
front of it) remains only for *old records with blank `chatPreviewText`*, true
plain-text-only mail, and forwarded lead-in compatibility. The closeout's exit
condition: "Revisit after a data backfill or metrics show missing stored
previews are rare enough to narrow further." The backfill is therefore a
one-time migration populating `chatPreviewText` for existing records where it
is blank, using the same derivation the ingest path applies
(rearchitecture item 6 made ingest populate it for all new messages).

**Live consumers at HEAD:**
- Read/write population: `MessageBubbleLoader+CompatibilityContent` — the
  "compatibility path for old records with missing chatPreviewText" (its own
  words). This is the only get/set consumer.
- Prefetch: `ChatViewModel` warms compat entries for visible windows.
- Invalidate-only: `HTMLContentRecoveryService`,
  `CanonicalEmailContentLoader`, `MessagePersister+Updates`,
  `CacheCoordinator` (via `MessageKeyedCache` since CX7).
- Static key/derivation helpers used from outside:
  `ProcessedTextCache.contentSourceSignature` (MessageBubbleLoader+HTMLAnalysis).
- DI plumbing: `Dependencies`, `ChatDependencies`, `MessageBubbleLoader`.

**Decision: backfill-then-delete.** Rationale: the only read population is
legacy records; ingest has populated `chatPreviewText` for all new messages
since phase 1; and `RenderedMessageCache` already owns a "legacy fallback
text" artifact (rearchitecture item 5), so the residual cold-start derivation
for stragglers can ride it after the backfill. Narrow-to-shim would leave a
1,278-line file guarding a shrinking population indefinitely.

Implementation series (its own PRs, not this campaign):
1. Migration pass backfilling blank `chatPreviewText` via the ingest
   derivation; ship and soak.
2. Move `contentSourceSignature` to the HTMLContentLoader cache-key home;
   point the compat read at `RenderedMessageCache`'s legacy-fallback artifact.
3. Delete `ProcessedTextCache` + its tests; drop its `MessageKeyedCache`
   conformance and DI plumbing.

## ORG2 — ProcessedTextCache retirement (investigation → L / medium risk)

**Evidence.** `Services/Caching/ProcessedTextCache.swift` (1,278 lines) is the
second-largest file in the repo. `decomposition.md` classifies it as a
"narrow/delete candidate pending the data backfill noted in the phase-1
closeout" — the live bubble render path moved to `ChatMessageRowModel` +
`RenderedMessageCache`. Deleting it is the single biggest line-count
reduction available and removes one CX5 copy and one CX7 cache.

**Plan.**
1. **Recover the backfill definition** — the phase-1 closeout
   (`rearchitecture.md`) was removed once shipped; retrieve it from git
   history (`git log --all --diff-filter=D -- rearchitecture.md`, then
   `git show <sha>^:rearchitecture.md`) and restate the backfill scope here.
2. **Map live consumers** of ProcessedTextCache at HEAD (which entry points
   still read through it, for which message populations — the legacy-compat
   population is the reason it exists).
3. Decide: backfill-then-delete vs narrow-to-shim. Write the outcome into
   this doc before implementation; implementation is its own PR series.

**Tests.** ProcessedTextCacheTests (until deletion), MessageDisplayPolicyTests,
MessageBubbleLoaderTests, plus whatever the consumer map surfaces.

## ORG3 — strict-concurrency ratchet (step 1: S / low risk)

**Evidence.** All six build configurations are `SWIFT_VERSION = 5.0` with no
`SWIFT_STRICT_CONCURRENCY` setting. The codebase mixes actors, `@MainActor`
classes, `@unchecked Sendable` (`CoreDataStack`, `GmailAPIClient`,
`MessageFetcher`), NSLock, and DispatchQueue with no stated convention.

**Plan.**
1. **Step 1 (cheap, do anytime):** set `SWIFT_STRICT_CONCURRENCY = minimal`,
   then `targeted`, and inventory the warnings — no code changes required to
   learn the shape of the migration.
2. Write the one-page convention the sync layer already follows implicitly:
   actors for stateful concurrent services; `@MainActor` for UI-coupled
   orchestrators; `Sendable` final classes for stateless utilities. New code
   conforms; existing code migrates opportunistically.
3. Full migration to `complete`/Swift 6 is explicitly **out of scope** for
   this campaign; it gets its own plan when the inventory says it's tractable.

---

## Explicit non-goals

Reviewed and deliberately excluded:

- **VirtualScrollState decomposition** (941 lines, ~5 responsibilities) — a
  legitimate future target, but freshly rewritten (U3′/U8) and
  guardrail-protected; let it stabilize. Revisit next campaign.
- **FullEmailWebViewManager** (1,528 lines) — already organized (17 types /
  14 MARKs); phase-2 disposition stands.
- **ChatMessagesCoordinator** — staged scroll tasks are intentional
  complexity per AGENTS.md.
- **Preview-builder line analyzers** (Transactional/Newsletter) — duplication
  deliberately kept per the phase-2 closeout; revisit only if a third
  consumer appears.
- **DI overhaul** — `Dependencies` stays the composition root; ~28 files
  still touch `.shared` directly, addressed by ratchet (new code takes
  injected collaborators), not a rewrite.
- **Initial/Incremental sync orchestrator convergence** and
  **SyncReconciliation decomposition** — real but lower-value; extract shared
  phase execution opportunistically when sync is next touched for other
  reasons.
- **Perf-plan Phase C backlog** (C1 batch endpoint, C2 constraints, C3
  metadata right-sizing, C4 RateLimitTracker rewrite, C5 retention, C6
  classifier unification, C7 parse-once, CP2) — tracked in
  `PR-DESCRIPTION.md`; CX7 intentionally clears C6's versioning prerequisite,
  otherwise untouched here.

## Verification

- Per PR: the item's `-only-testing` slice (listed per item) via
  `./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/<Suite>'`.
- Per series end: full suite (`./Scripts/codex-test.sh`).
- CX4 retry semantics are verified at the URLProtocol level against the real
  client only — mock-client tests prove nothing about retry accounting.
- CX6 additionally gets an on-device spot check (full email open, preview
  render) — WebView behavior is a guardrail area.
- No pbxproj edits anywhere: synchronized root groups pick up new/moved
  files automatically.

## Definition of done (per item)

- Characterization tests existed or were added before code moved.
- The canonical implementation has exactly one home; former copies delegate
  or are deleted.
- Relevant `-only-testing` slice and, at series end, the full suite are
  green — or the exact gap is stated.
- No new warnings in touched scope.
- The Status table above is updated with PR numbers; item-specific decisions
  (CX3 divergences, CX7 actor decision, ORG2 disposition) are recorded in a
  closeout note appended to this doc, following the `decomposition.md`
  convention.

---

## Closeout notes (2026-07-05)

All work shipped as one-concern PRs in the campaign's sequence: #97 (CX1),
#98 (CX2), #99 (CX3), #104 (CX4), #100 (CX5), #101 (CX6), #102 (CX7),
#103 (ORG3), #105 (ORG1 + docs).
Every item followed the working method: characterization tests ran green
against the duplicated code before extraction, then again after delegation.

### What landed where

- **CX1** — `Services/Models/AttachmentDisplayFiltering.swift`:
  `DisplayFilterableAttachment` protocol + `AttachmentDisplayFilter` engine;
  `Message` and `ChatMessageRowModel` delegate (~200 duplicated lines
  removed). New `AttachmentDisplayFilterParityTests` runs both copies against
  one fixture set across the full flag matrix.
- **CX2** — `Services/TextProcessing/TextPatterns.swift` (`EmailPatterns`,
  `URLPatterns`, `SignaturePatterns`, `QuoteHeaderPatterns`, `MIMEPatterns`)
  and `TextProcessing.normalizeLineEndings`. Swapped in:
  PlainTextSignatureRemover, PlainTextQuoteRemover, RawEmailSourceSanitizer,
  EmailDOMQuoteRemover+Signatures, ProcessedTextCache, TextProcessing
  (a third inline line-endings copy in `unwrapEmailLineBreaks`, and
  `signatureDelimiterPattern`). New `PlainTextSignatureRemoverTests`
  (17 cases) closes the doc's characterization gap.
- **CX3** — `Services/ErrorHandling/APIErrorRecovery.swift`:
  `BackgroundSyncRecoveryAction` moved here; `APIError.recoveryAction` is the
  canonical mapping with `isRetriableSameRequest` derived from it. Delegates:
  `RetryStrategy`, `MessageFetcher`, `BackgroundSyncErrorHandler` (thin
  adapter), and `PendingActionProcessor.shouldRetryError` — a **fourth**
  classifier the plan had not listed. `RetryExecutor.swift` deleted
  (`ExponentialBackoff` kept; TokenManager uses it).
- **CX4** — one engine, `GmailAPIClient.performRetryingRequest`, parameterized
  by a status closure (the intentional 404 divergence: `notFound` vs
  `historyIdExpired`) plus a `GmailRetryPathBehavior` struct. Both public
  paths delegate. Added history-path parity tests for the [401,401] and
  [401,500,200] sequences (green before and after the extraction).
- **CX5** — `Services/TextProcessing/HTMLCleanupFallback.swift`
  (`cleanedHTML(from:modes:)`); the three copies delegate. New
  `HTMLCleanupFallbackTests` pins the chain on all three fixture classes and
  asserts the `prepareHTMLForDisplay` seam equals the canonical chain.
- **CX6** — `Views/Components/EmailContent/EmailWebViewLoadCoordination.swift`;
  both coordinators compose it (no class hierarchy). Mode differences are
  injected: `requiresViewportHeight` (preview true / full reader false — the
  one readiness divergence between the copies) and `onSignatureChange` (full
  reader's paint-confirmation invalidation). Coordinator member surfaces are
  unchanged, so existing tests run as-is.
- **CX7** — `Services/Caching/MessageKeyedCache.swift` (protocol + shared
  `MessageCacheInvalidationReason`) with conformances for ProcessedTextCache,
  RenderedMessageCache, HTMLContentLoader, HTMLContentResultCache;
  CacheCoordinator routes message-deletion invalidation through the protocol.
  `Services/Caching/CacheVersioning.swift` now owns `processingVersion` and
  the preview snapshot `rendererVersion` (the C6 prerequisite).
- **ORG1** — all 61 loose Services files moved into domains (new:
  `Attachments/`, `HTMLContent/`, `Dependencies/`); `esc-chatmail/Conversations/`
  folded into `Services/Conversation/`; all loose test files mirrored into
  domain folders; AGENTS.md / decomposition.md / this doc path references
  updated. Pure moves — no content edits.
- **ORG3** — `SWIFT_STRICT_CONCURRENCY = minimal` landed explicitly in all
  six configurations (ratchet floor; builds clean, zero warnings). Convention
  written to `CONCURRENCY.md`.

### Decisions (divergences surfaced, not silently unified)

- **CX3 classification decisions** (each was a live divergence):
  - `invalidURL` / `decodingError` / `notFound`: BackgroundSyncErrorHandler
    previously fell through `default:` to `.retry` (the M1 inverted-intent
    class); canonical mapping classifies all three `.abort`. Retry
    classifiers already treated them as non-retriable.
  - `networkError`: MessageFetcher previously said non-retriable (its
    `default:`); canonical says retriable, matching RetryStrategy and
    BackgroundSyncErrorHandler. Practically unreachable in MessageFetcher
    (the client surfaces raw URLErrors, not `.networkError`, on that path).
  - `serverError(<500)`: was blanket-retriable in RetryStrategy /
    MessageFetcher / PendingActionProcessor; canonical derives retriability
    from `code >= 500` (matches BackgroundSyncErrorHandler). Unreachable in
    practice — the client maps 4xx to `invalidData`/`notFound` before any
    `serverError` escapes.
  - Same-request retriability is `recoveryAction == .retry`, deliberately
    narrower than the plan's sketched `!= .abort && != .abortNoRetry`:
    `partialSync` and `tokenRefreshAndRetry` recover by doing something
    *different*, and every legacy classifier already treated
    `historyIdExpired`/`authenticationError` as non-retriable.
  - **RetryExecutor**: deleted rather than adopted. Its one caller
    (AttachmentDownloader) stacked a second 3-attempt loop on the client's
    own retry loop (up to 9 HTTP attempts); the client loop is now the single
    retry owner (M2 convention). Attachment downloads go from ≤9 to ≤3
    attempts on transient network errors.
- **CX4 unifications** (History adopts message-path semantics):
  - 429 accounting order — History previously ran `recordBackoff` *before*
    its breaker checks, recording delays it never slept (the unfixed M6
    remnant); the engine records only slept delays for both paths.
  - Thrown `rateLimited` now carries the capped Retry-After on the history
    path too (was `retryAfter: nil`); pinned by a new history test.
  - Preserved per-path (as explicit `GmailRetryPathBehavior` knobs, candidates
    for later unification): History hard-aborts on any thrown APIError while
    the message path lets `RetryStrategy` mediate (observable only for
    breaker-tripped 429s); DecodingError wrapping (message wraps into
    `APIError.decodingError`, history propagates raw); success handling
    (message: any 2xx + EmptyResponse + embedded-error check; history: 200
    only, non-HTTP response → `networkError`).
- **CX2 divergences left in place** (surfaced for a future pass):
  - `TextProcessing.signOffWords` lacks `"best regards"`, which
    `PlainTextSignatureRemover.signOffWords` includes.
  - EmailDOMQuoteRemover's signature title/organization keyword lists carry
    extras (`specialist`, `llp`, `lp`) the plain-text lists lack.
- **CX7 actor decision**: `HTMLContentResultCache` stays a locked class. Its
  NSCacheDelegate eviction path re-enters synchronously from arbitrary
  threads, which an actor cannot host, and its call sites are synchronous
  loader hot paths. The unified protocol wraps it; its lock-discipline header
  comment stands.
- **ORG2 disposition**: backfill-then-delete (full note in the ORG2 section
  above).
- **ORG3 inventory**: `targeted` does not compile — three Sendable errors,
  all non-Sendable types crossing actor-isolated protocol witnesses
  (`ContactsResolver.lookup` returning `ContactMatch?`;
  `ActionExecutor.execute` taking `[String: Any]?`, two witnesses). Moving
  the ratchet to `targeted` is a small dedicated PR (make `ContactMatch`
  Sendable; replace the payload dictionary with a Sendable value type).
  Details in `CONCURRENCY.md`.

### Verification run

- Per-item `-only-testing` slices: all green (CX1 97, CX2 312, CX3 101,
  CX4 43, CX5 194, CX6 44, CX7 140 test cases).
- One flaky crash observed once in `AttachmentDownloaderTests
  .testFetchAttachments_usesBatchSize` (process crash "at <external
  symbol>", the known parallel-testing Core Data flake TestCoreDataStack's
  comments document); deterministic pass on rerun with identical code.
- Full app build: clean, zero warnings, with the explicit
  `SWIFT_STRICT_CONCURRENCY = minimal` landed.
- Full suite at series end, after the ORG1 moves: **2,356 test cases, all
  green** (`./Scripts/codex-test.sh`).

### Known gaps

- **CX6 on-device spot check not performed** (full email open, preview
  render, rotate/resize) — requires a device/simulator UI session; the four
  WebView test suites are green and coordinator surfaces are unchanged, but
  the guardrail deserves the manual pass before merge.
- **CI cannot currently go green**: the Build & Test job's 90-minute
  timeout kills every run in this repo's history (including PRs #94/#96 and
  every push to main). The campaign PRs (#97-#105) were therefore merged on
  local verification — per-item isolated slices, the full 2,356-test suite,
  zero-warning builds, SwiftLint, and byte-exact diff review — by owner
  decision. Fixing the workflow (shard/raise timeout) is tracked as its own
  task.
- The pbxproj gained the six `SWIFT_STRICT_CONCURRENCY` lines (ORG3) — the
  "no pbxproj edits" note in Verification refers to file moves, which indeed
  required none.
