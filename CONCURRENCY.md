# Concurrency Convention

Last updated: 2026-07-05 (ORG3 step 1 of `consolidation.md`)

One page: the convention the sync layer already follows implicitly, now
stated. New code conforms; existing code migrates opportunistically when
touched for other reasons.

## Roles

- **Actors** for stateful services touched from multiple tasks — caches and
  trackers with mutable indexes (`ProcessedTextCache`, `RenderedMessageCache`,
  `RateLimitTracker`, `PersonCache`). If a type owns mutable state and its
  callers are async, it should be an actor, not a locked class.
- **`@MainActor`** for UI-coupled orchestrators and anything SwiftUI observes
  (`CacheCoordinator`, view models, `Dependencies` accessors that vend
  main-actor services).
- **`Sendable` final classes / enums** for stateless utilities and namespaces
  (`TextProcessing`, `AttachmentDisplayFilter`, pattern namespaces). Pure
  functions + immutable stored properties only.
- **`@unchecked Sendable`** is a debt marker, not a convention. The three
  current holders (`CoreDataStack`, `GmailAPIClient`, `MessageFetcher`) carry
  internal synchronization (Core Data queues / URLSession / bounded task
  groups); do not add new ones without a comment stating the synchronization
  that justifies it.
- **NSLock'd classes** are acceptable only where a synchronous API is
  structurally required. The canonical example is `HTMLContentResultCache`:
  NSCache's delegate re-enters synchronously on eviction, which an actor
  cannot host (see its header comment). Every locked class documents its lock
  discipline.

## Build-setting ratchet

- `SWIFT_STRICT_CONCURRENCY = minimal` is set explicitly in the project (all
  configurations) as the ratchet floor. The setting only moves forward
  (minimal → targeted → complete), never back.
- **`targeted` is not yet clean.** The 2026-07-05 inventory build
  (`./Scripts/codex-build.sh SWIFT_STRICT_CONCURRENCY=targeted`) fails with
  three Sendable errors, all the same shape — non-Sendable types crossing
  actor-isolated protocol witnesses:
  - `ContactsResolver.lookup(email:)` returns non-Sendable `ContactMatch?`
  - `ActionExecutor.execute(...)` takes non-Sendable `[String: Any]?` payload
    (two witnesses)
- Moving the ratchet to `targeted` means making `ContactMatch` Sendable and
  replacing the `[String: Any]` action payload with a Sendable value type —
  small, mechanical, worth its own PR. Full migration to `complete`/Swift 6
  is out of scope for the consolidation campaign and gets its own plan.
