# Performance, reliability & scalability improvements (plan v2)

Implements the reviewed v2 plan end-to-end on `claude/performance-reliability-scalability-9hb8w4` (base `02f3ebc`): 33 commits total, including the 29 scoped implementation commits plus follow-up review-fix commits. The implementation series keeps one concern per commit, with matching XCTest coverage. Full suite: **2229 tests, 0 failures**. A multi-session adversarial review loop ran over the whole series until clean (details at the bottom).

## What changed

**Sync / API quota & reliability**
- **M0** — Label reconciliation (the largest steady-state API consumer: ~1 list + up to ~100 metadata GETs per push-triggered sync) is TTL-gated at 20 minutes when history reported changes; the hourly force interval for quiet syncs is unchanged. The missed-message check stays per-sync by design (cheap single list call; it is the data-loss safety net).
- **M6** — A successful 401 token refresh no longer consumes a retry attempt in either retry loop; previously a refresh on the final attempt exited as non-retriable `URLError(.unknown)` and could send a whole fetch batch to `permanentlyFailedIds` after routine token expiry. History's 429 branch also gained its missing final-attempt guard.
- **M2** — MessageFetcher is now the single retry owner (client called with `maxRetries: 1`, a real protocol requirement so the budget dynamically dispatches; the 15s `withTimeout` wrapper that amputated inner backoff is gone). `APIError.rateLimited` carries the capped server Retry-After and the outer backoff honors it; breaker backoff is no longer recorded for delays never slept. BackgroundMessageProcessor and HTMLContentRecoveryService deliberately keep the client's inner retries (no outer loop of their own).
- **M1** — History retry error mapping reaches parity with the main client: revoked refresh token → `credentialsRevoked` (abort-no-retry, not refresh loops); unhandled 4xx → non-retriable `invalidData`; `BackgroundSyncErrorHandler` gained the missing `invalidData → abort` leg.
- **M3** — Rate-limit success credit 30s → 2s (mitigation; structural rewrite deferred, C4).
- **M5** — Send-as alias refresh TTL-gated at 24h, keyed per account email; the skip path still hydrates the in-memory alias managers from the persisted account.
- **L3** — Initial-sync profile + sendAs fetched concurrently.
- **L2** — TokenManager caches (token, expiry) under a lock: no keychain read or MainActor hop per API request; full writer sweep (save/refresh/clear/sign-in/sign-out) keeps the cache truthful.

**Core Data**
- **S1** — Persistent history (tracked but never consumed) is purged past 7 days during cleanup, best-effort in its own do/catch; the dead remote-change notification option was dropped. Note: cleanup runs from a daily BGTask at iOS discretion — a foreground hook is a possible follow-up.
- **P1** — Person lookups go through a context-scoped cache primed once per save batch (was 3–4 fetches per participant per message across creation, conversation routing, and display-name enrichment). Also fixes a latent `Dictionary(uniqueKeysWithValues:)` trap on legal duplicate-email Person rows and normalizes emails at the factory boundary.
- **R1** — Merge-conflict save recovery refreshes with `mergeChanges: true` (was `false`, discarding the very edits being saved) plus a brief attempt-scaled pause. Near-unreachable path; review-only change.

**UI / rendering**
- **U1** — All 6 uncosted `NSCache.setObject` sites now pass costs (decoded-bitmap formula for images, compressed byte size for photos), making the existing `totalCostLimit`s real.
- **U2** — Disk-cached images decode through a CGImageSource downsampler capped at 1440px; consumer audit (verified again in review) found nothing rendering beyond bubble-width cards/avatars; QuickLook/attachments use their own full-resolution path.
- **U5/U7** — The conversation list no longer does ~7 set-passes per merge for irrelevant changes (type-check-only relevance guard, refreshed-set kept for rollup updates) and no longer runs a redundant always-on `@FetchRequest` in parallel with the view model pipeline.
- **U8** — With a chat open, merges no longer fault every inserted message's Conversation row and labels on the main thread: type-level early guard plus objectID-based conversation membership (one-time objectID fetch; temporary IDs never cached).
- **U3′** — The virtual scroll window is bounded (`maxWindowSize`, default `max(200, pageSize·6)`, clamped to a viable minimum). Back-trim only, applied while extending upward where removed rows are below the viewport; front-trim deliberately absent (no offset compensation exists; out-of-window jumps already collapse the window). Reviewed behavior change: a trimmed window makes `isShowingLatestWindow` false while scrolled up, so mid-scroll inserts take the count-only branch; post-send recovery still works.
- **U6′** — MessageBubbleLoader is a stateless Sendable class instead of an actor (the actor serialized per-bubble CPU-bound HTML analysis through one executor for zero safety gain).
- **CP4** — `Message.isLikelyCalendarInvite` is memoized (objectID + input fingerprint) — it ran a sanitizer pass + three normalizations + regex per row-model mapping.
- **D1** — Deleted production-dead code: `updateDenormalizedFields()` (would have corrupted `inboxUnreadCount` if ever called), Message's HTML-loading attachment paths (near-verbatim duplicates of MessageBubbleHTMLAnalysisBuilder; tests ported to the live analysis-based path), and VirtualScrollChatView + MainTabView + InboxListView (tests retargeted to the live surfaces).

**Chat content pipeline**
- **CP1a** — The `div[class*=sig]` selector removed `design`/`signup-form`/`insights`/`assignment-list` content (de[sig]n, [sig]nup, …). Signature divs are now matched by whole class-name token; the other substring selectors are deliberately unchanged (token-anchoring them would regress `footerContainer`/`footer_wrap`-style templates). Backed by new characterization tests (the function previously had zero).
- **CP1b′** — Footer removal skips any matched element holding ≥60% of the document's visible text — fixing whole-bubble wipeouts at the source instead of relying on the downstream empty-content degradation chain (which exists in three copies). Per-element, fixed original-document baseline; a content-loss ratio guard was considered and rejected (it would restore quoted threads).
- **CP6-lite** — `stripAppleRichLinkPreviews` resumes scanning from the removal point instead of index 0 (k blocks cost one pass, not k).

## Phase C — deferred (documented per plan)

- **C1 (H1+M0 residue)**: Gmail per-API `/batch` for message fetches — needs hand-rolled multipart with per-part status parsing reproducing the current error classification; build-capable session + live-API validation.
- **C2 (S4)**: uniqueness constraints for **Person.email and Conversation identity only** (`Message.id` is already model-constrained and runtime-enforced); requires a two-release dedupe-then-constrain rollout.
- **C3 (H2)**: `format=metadata` right-sizing — bundle with C1.
- **C4 (M3 structural)**: RateLimitTracker leaky-bucket/time-decay rewrite; the 2s credit is a stopgap.
- **C5 (S2)**: retention pruning (`messageRetentionDays`, default off) — product decision.
- **C6 (CP3)**: unify the 5 newsletter/transactional classifiers (precedent: CalendarInviteSignals, 47dd388); requires a `processingVersion` bump.
- **C7 (CP6)**: parse-once refactor — EmailDOMQuoteRemover mutates the DOM and the fragment-vs-document output contract feeds compose-time reply quoting.
- **CP2**: narrowing blockquote/border-left removal — needs on-device visual verification.

## v1 → v2 corrections carried into implementation

- CP1's content-loss ratio guard **rejected** (would restore quoted threads) → per-element majority-text guard; CP1 selector change narrowed to `sig` only.
- U6 hoist **replaced** with de-actoring (the hoist contradicted the per-row factory design and would serialize bubble loads).
- P4 and CP5 converted from optimizations to **deletions** (dead at HEAD).
- U3 front-trim **dropped** (scroll-jump risk); back-trim + natural collapse only.
- M2 explicitly depends on M6 (landed first; without the refresh grant, `maxRetries: 1` would drop batches on routine token expiry).

## Verification

- Full suite green at every commit boundary touched; final: 2229 tests, 0 failures. API-client retry semantics tested at the URLProtocol level against the real client; VirtualScrollStateTests + ChatMessagesCoordinatorTests (the 18b19de guardrails) stay green.
- **Adversarial review loop** (fresh sessions, loop-until-clean): subsystem reviewers over all commits (sync/API, Core Data/caching, content pipeline, UI/scroll) plus scoped residue reviewers. No functional bugs found; the three low-severity findings (stale doc pointers to a deleted view, two overclaiming comments, a lost coverage pin for plain-text calendar invites) are fixed in the final commit. A round-2 review of those fixes came back clean.
- **On-device passes for the owner** (per plan): chat scroll feel (window cap), chat open during heavy sync (U8), bubble content spot-check (CP1a/CP1b′).
