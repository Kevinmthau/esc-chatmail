# Scalability review: years of use, 100k+ messages

Written 2026-10-22 against `main` at `750a2448`. Read-only review; no code was changed.

## Verdict

**Thousands of messages: yes.** At about 15k messages the bounded paths hold. Lookups are indexed, the chat window is capped at 300 rows, the caches have count and byte limits, the initial sync only covers mail since install, and history slices commit durably. Measured costs stay in the tens of milliseconds, and the SQLite store is about 60-75 MB. The one hard failure already reachable at this size is a multi-select archive or Report Spam that covers more than 1,000 messages. Gmail rejects it, the action is silently abandoned, and the mail stays in the Gmail inbox.

**Years of use: not yet.** The app does not corrupt data or lose its sync cursor as it grows, but it degrades steadily, because many paths cost O(lifetime conversation) or O(mailbox) per touch instead of O(change). The biggest structural tax is that every sync context materializes the whole INBOX label membership and the user's own Person participations through Core Data inverse to-many relationships. That measured 100 ms and +49 MB per sync at 120k messages, and 1.2 s and +172 MB at 400k, on a Mac. Archive, chat open and list scrolling grow with conversation or unread size on the main thread. Disk use has no ceiling: roughly 9-17 GB at 120k messages, all of it in the iCloud backup.

It also **breaks on specific events**, all reachable by a long-time user:

- **Re-sign-in on an old install.** Signing out and back in, or a store reset, re-lists everything since the original install in one sync context that is never refreshed and cannot resume. That is about 1.6 GB of resident objects at 400k messages, then a jetsam kill and a restart from page 1. A same-account re-sign-in after Gmail's history has expired takes the same path through history recovery.
- **A full disk or I/O error at launch.** Any store-load error that is not a timeout or a migration error deletes the store. That includes the user's queued actions and sent attachments that cannot be re-downloaded.
- **A failed fetch during the nightly attachment sweep.** The sweep treats the failure as "no valid files" and deletes every attachment on disk.
- **The web PWA** has three breakers of its own: a full-table participant repair, history truncation that keeps no continuation token, and an IndexedDB quota error that wedges sync permanently.

None of this needs a rewrite. Most fixes are local, and the structural ones fit into a single new model version (ESCChatmail 7) plus a SQLite-backed scale test harness.

## How this review was done

- Twelve auditors each covered one subsystem: schema and indexes, initial sync, incremental sync, the persist path, the conversation list, the chat transcript, launch passes, disk, background and pending work, memory and caches, persons and contacts, and the web PWA.
- A completeness critic then found five more areas, and a second round audited them. They were disk-full behaviour, file reclamation on delete, SQLite file-level growth, an empirical scale harness, and contradictions between the first-round reports.
- That produced 153 findings. Three independent verifiers checked each one: one tried to refute it, one judged at what scale it bites, and one checked the fix against this repo's invariants. 151 findings survived, many with corrected mechanisms or lowered severities.
- Theme agents merged the duplicates into 88 items. A final review checked every breaking and degrading item against the code and `CLAUDE.md`. It corrected 21 recommendations, mostly sync-cursor safety traps and temporary-objectID cases, and changed 4 severities. Those corrections are included below, marked "Review correction".

**About the numbers.** "Measured" means a harness agent seeded synthetic SQLite stores to the S2/S3 shapes and timed them on an M5 Pro Mac using the real v6 model. Expect 2-4x slower on an iPhone. Two inputs to those seeds are assumptions, not measurements: about 81% of messages carry INBOX and about 22% are unread. Every hub-fault, archive and chat-open timing scales with those two numbers. "Estimated" means derived from code and arithmetic. The Gmail 1,000-ID batchModify limit is documented but was not exercised against the live API.

## Reference scales

The year labels are rough. What matters is mailbox size.

| Scale | Messages | Conversations | Persons | Notes |
|---|---|---|---|---|
| S1 | 15k | 1.5k | 2k | Light user, about a year |
| S2 | 120k | 12k | 8k | Heavy user, a few years; about 25k attachments and 3 GB of HTML |
| S3 | 400k | 30k | 20k | Newsletter-heavy power user, five or more years |

## Capacity model

| Quantity | S1 | S2 | S3 | Basis |
|---|---|---|---|---|
| Message / MessageParticipant / label-join rows | 15k / ~40k / ~35k | 120k / ~310k / ~280k | 400k / 1.04M / 916k | S3 measured in the seeded store (2.6 participants and 2.3 labels per message); S1 and S2 scaled |
| INBOX label members / self-Person participations | ~12k / ~15k | ~97k / 120k | ~319k / 400k | INBOX share is a seed assumption (81%). The self Person gets one participation per message because `saveParticipants` never excludes the owner |
| SQLite store file | 61-73 MB | 718-773 MB | 2.34-2.46 GB | Measured, with 3-4 KB mean bodyText. About 90% is `ZMESSAGE`, mostly inline bodyText |
| HTML bodies on disk (flat `Documents/Messages`) | 15k files, 0.3-0.5 GB | 120k files, ~3 GB | 400k files, 10-20 GB | Estimated at 25-50 KB per body. No retention, cap or compression |
| Attachments plus previews | ~1 GB | 6-13 GB | 15-30 GB | Estimated at a 200-400 KB mean. Every attachment is auto-downloaded and never evicted |
| iCloud backup footprint | ~1.5 GB | 9-17 GB | 30-50 GB | Estimated sum. Nothing sets `isExcludedFromBackup` |
| Store backup left by each reset or migration failure | ~70 MB | ~0.7-0.8 GB | ~2.3-2.5 GB | About one store's size per event. Never pruned, and survives sign-out |
| Persistent-history rows after a since-install re-list | 108k / 4 MB | 862k / 31 MB | 2.9M / ~100 MB | Measured at 7.2 change rows per message. Steady state is under 1 MB a week, but only if the daily BG purge runs |
| Largest single conversation | 1-2k | 1-3k typical, up to ~20k | 5-20k | Estimated. Conversations never split on archive, so a notification sender or list keeps growing |
| Hub-fault cost per sync (one new message, fresh context) | tens of ms | 100 ms warm, 3.8 s cold, +49 MB | 1.24 s, +172 MB (cold not measured; BG and push runs pay cold) | Measured |
| Chat open: unread snapshot | <20 ms | ~40 ms warm, ~1 s cold | ~150 ms warm, 2.6-3.3 s cold | Measured. Scales with unread mail across the whole mailbox |
| Chat open: first page plus count, without `sqlite_stat1` | <20 ms | 150-300 ms each | ~1 s each | Measured. With stats both drop to under 60 ms; stats exist only after the daily BG ANALYZE |
| Archive of the largest conversation | negligible | 5.6 s, +207 MB (20k messages) | 11.7 s, +237 MB (19k) | Measured as a private-context replay. Production runs it on the main thread |
| Re-sync after sign-in on an old install | ~75k quota units, 6-17 min | ~600k units, 1-2.5 h, 4-12 GB | ~2M units, 3-8 h | Quota math (5 units per get, 250 units/s per user). Throughput estimated |
| Peak memory held by that re-sync's context | ~60 MB | ~470 MB+ | ~1.6 GB+ | Measured at 3.9 MB per 1k messages, extrapolated |
| Sign-out file deletion on the auth critical path | 1-3 s | 3-25 s | 10-75 s | Estimated at 20-150 µs per unlink |
| Weekly raw VACUUM | 138 ms | 1.6-1.9 s, WAL grows to 684 MB | 7.3 s, WAL 2.33 GB, reclaims 27 MB | Measured. Needs about 2x the store size in free disk |
| Web IndexedDB size / participant-repair load | 0.4-0.6 GB / 60-90 MB | 3.5-3.7 GB / 0.5-0.7 GB | 8-10 GB / 1.6-2.4 GB | Estimated |

## Root causes

Most of the items below come from a handful of patterns. Fixing the pattern usually fixes several items.

1. **Conversation-wide walks on every touch.** Rollups, archive, Report Spam, inbox-indicator refreshes, send-echo consumption, header-name loads and several repairs read every message of a conversation through `conversation.messages` or an unlimited fetch. Bounded count, limit or keyset queries over `byConversationAndDateIndex` would do. Because `bodyText` and the preview columns are inline, each walk also loads every body.
2. **Mailbox-sized inverse to-many relationships on hub objects.** System labels (INBOX, UNREAD, CATEGORY_*) and the user's own Person each relate to most messages. Any add, remove or delete makes Core Data realize the whole inverse set in that context. Every sync run, BG task and cleanup pass builds a fresh context, so the cost is paid again each time.
3. **Unindexed predicates, OFFSET paging, and plans that depend on a daily ANALYZE.** The transcript and the unread snapshot filter on `conversation.id`, an unindexed UUID join. The list and the transcript page with OFFSET or re-fetch from offset 0. `sqlite_stat1` exists only after a BG ANALYZE, so fresh or reset stores get full `ZMESSAGE` scans. Index-only model edits never migrate, so dead and duplicate indexes linger.
4. **O(N) work on the main thread.** `MessageActions`, `ConversationLaunchRepairCoordinator`, `DatabaseMaintenanceService` and the list and transcript view models fetch, save, walk directories and rebuild snapshots on the main actor. There, even moderate O(N) costs become visible hitches.
5. **Long passes with no resume point, anchored to install time.** Re-initial sync and history recovery window from `installTimestamp`, which survives sign-out. Neither keeps a page-token checkpoint or refreshes its context, and neither skips IDs already stored. Web truncation, BG refresh slices and destructive history slices share the same commit-only-at-the-end shape.
6. **Store-wide maintenance on timers inside latency- or budget-sensitive paths.** The six-hourly passes run inside the sync run and inside BGAppRefresh slices. One of them, `removeDuplicateMessages`, is provably dead. The weekly VACUUM rewrites the whole store, and BG maintenance ignores expiration and cannot be cancelled by sign-out.
7. **Content stored twice, kept forever, and backed up.** Each body is an HTML file and again inline `bodyText`. Attachments are downloaded eagerly, with a duplicate preview copy. Deletions never unlink files, because the post-save plan reads tombstones. Backups and persistent history are never pruned, and nothing is excluded from iCloud backup.
8. **Resource-exhaustion paths that fail open, destructively or silently.** The store-load ladder treats any unknown error as corruption. An out-of-space write persists a body-less row. The attachment sweep reads a failed fetch as "no files". The only disk-full classifier is dead code.
9. **Scale is invisible to the test suite.** `PerformanceRegressionTests` run on an in-memory store with a few hundred conversations, so SQL plans, index use and fault costs cannot regress visibly.


## Will break

These fail outright: lost user intent, a deleted store, a crash loop, or a permanent sync wedge. Each fires on a specific event rather than on steady growth.

#### Conversation archive and Report Spam send every message ID in one Gmail batchModify; more than 1,000 IDs is rejected and the action is abandoned silently

`archive-spam-batchmodify-no-chunking` · ios · effort S

**Problem.** GmailActionExecutor chunks only .markRead by gmailBatchModifyLimit = 1_000. The .archiveConversation and .reportSpam branches pass the whole payload ID list to a single apiClient.batchModify. That list holds every lifetime message of the conversation, not just its INBOX rows, and multi-select concatenates the lists of all selected conversations. Gmail's documented 1,000-ID cap returns a 4xx, which maps to APIError.invalidData -> .abort, so PendingActionProcessor abandons the row on the first attempt. By then the local archive or spam change has already been saved, and the only signal is a .pendingActionFailed post that nothing observes.

**When it bites.** Already at S1 through multi-select: about 25 chats of 40 messages each, or select-all on about 100 ten-message chats. For a single conversation it bites once any 1:1 or list chat passes 1,000 lifetime messages (a daily newsletter after about 3 years, or S2/S3 notification senders). When it bites, 100% of that archive or spam never reaches Gmail and is never retried.

**What the user sees.** Archive or Report Spam looks done in the app, but the mail stays in the Gmail Inbox on the web and other clients, and spam is never reported. No error is shown, and a later reconciliation can bring the chat back.

**Fix.** Wrap the .archiveConversation and .reportSpam calls in the same `for batch in messageIds.chunked(into: Self.gmailBatchModifyLimit)` loop that markRead uses. Label add/remove through batchModify is idempotent, so re-running every chunk on a retried action is safe; this is not the non-idempotent send path. Do not narrow the ID set: SPAM must be added to every message, and sending all IDs on archive self-heals local/remote INBOX drift. Add a one-shot repair that re-queues abandoned archiveConversation/reportSpam rows whose payload exceeds 1,000 IDs, because the fix alone does not revive them. Also observe .pendingActionFailed (see pending-action-abandoned-rows).

**Review correction (supersedes the fix above where they conflict).** Ship the chunking loop as written. If you re-queue already-abandoned rows, limit that to rows newer than about 24 hours. The localModifiedAt guard lapses after 30 minutes (`SyncConfig.maxLocalModificationAge`), so replaying an old archive or spam would override what the user has done since. Surface older rows through the abandoned-action query API instead. Rewrite PendingAction rows only under the non-exclusive account-work lease.

**Keep intact.** Keep gmailMessageIDForConversationAction's exclusion of optimistic local IDs. Keep stamping localModifiedAt on every target row, because HistoryProcessor.hasPendingLocalModification depends on it during the pending window. The outbound-send non-idempotency rules are unaffected.

**Tests.** In ActionExecutorContractTests, next to testGmailActionExecutor_markReadPayloadChunksBatchModifyRequests, add testGmailActionExecutor_archiveConversationPayload_chunksBatchModifyRequests and testGmailActionExecutor_reportSpamPayload_chunksBatchModifyRequests. Each uses 2,001 IDs and asserts batches of [1_000, 1_000, 1] with the correct label sets, and carries a Revert-check naming the chunked loop. Add an end-to-end MessageActionsTests multi-select case that produces more than 1,000 IDs.

**Evidence.**
- `esc-chatmail/Services/PendingActions/ActionExecutor.swift:25` gmailBatchModifyLimit = 1_000
- `esc-chatmail/Services/PendingActions/ActionExecutor.swift:49` markRead is the only branch that chunks
- `esc-chatmail/Services/PendingActions/ActionExecutor.swift:80` archiveConversation single batchModify over all IDs
- `esc-chatmail/Services/PendingActions/ActionExecutor.swift:102` reportSpam single batchModify over all IDs
- `esc-chatmail/Services/PendingActions/MessageActions.swift:804` every conversation message's Gmail ID appended
- `esc-chatmail/Services/PendingActions/MessageActions.swift:522` multi-select concatenates IDs across conversations

**Caveats.** The 400 response is taken from Gmail's documented limit and was not exercised against the live API. The post-success clearLocalModifications `id IN` fetch over 10k-20k IDs was not measured.

#### Store-load recovery deletes the store on disk-full, I/O and data-protection errors, and its non-destructive branch leaves launch spinning forever

`store-load-recovery-ladder` · ios · effort M

**Problem.** CoreDataErrorClassifier.recommendedAction looks only at the top-level error.code. Timeouts and save conflicts retry up to 3 times, migration codes go to migrationRecovery, and everything else goes to .storeReset. That includes out-of-space (640, or SQLITE_FULL/CANTOPEN wrapped in 256/134180), SQLITE_IOERR, data-protection 257, and timeouts once their retries run out. Both destructive branches clone a backup and then call removeStore. Restore then finds no Account row while mailbox files exist, so performDurableLocalCleanup deletes every body and attachment, including local_ sent originals that cannot be refetched, along with queued PendingActions and send markers. If the backup copy throws instead, the error latches in a lazy persistentContainer that never reloads, and preparePersistenceUntilReady loops every 1 s with no message to the user.

**When it bites.** Possible at any scale, triggered by an event: launching on a full device, a model upgrade that needs free space, a protected-data launch (including BGTask cold launch), or an I/O fault. The cost is the whole mailbox. At S2 that means about 120k messages re-fetched over hours, plus every queued action, send marker and local-only sent attachment. If the backup clone fails instead, the app is unusable until force-quit.

**What the user sees.** After an iOS update or a stretch of low storage, the user opens the app to an empty mailbox and an hours-long re-sync; offline archive/read actions are gone and their own sent attachments show broken thumbnails. Alternatively the app sits on its loading spinner forever with no 'storage full' message.

**Fix.** Turn .storeReset into an explicit allow-list: NSFileReadCorruptFileError (259) plus an underlying SQLITE_CORRUPT/NOTADB found by walking NSUnderlyingErrorKey and the NSSQLiteErrorDomain userInfo. Classify out-of-space (640, ENOSPC, SQLite 13), CANTOPEN (14), IOERR (10), 257/SQLITE_AUTH and exhausted timeouts as non-destructive: keep the store and latch a typed load error. Treat a migration failure caused by SQLITE_FULL the same way. Ship this together with a working retry: add CoreDataStack.retryLoadAfterFailure(), which clears the latched error and reloads when persistentStores is empty. Surface the typed error in AppLoadingView with a 'free up storage / retry' message, gated on volumeAvailableCapacityForImportantUsage, and either observe or delete the CoreDataCriticalError post. Stop the 1 s loop from re-running FreshInstallHandler on every iteration. Use the shared out-of-space predicate from dead-disk-full-classification, and update the tests that pin 'exhausted timeout -> .storeReset'.

**Keep intact.** A failed Core Data read is never treated as 'absent' or 'empty'. Never publish authenticated UI before prepareLocalStoreForAuthenticatedAccount returns, and never weaken the isolation check to avoid the cleanup cascade. Never mutate the loaded model at runtime. No release-path fatalError; the new load error is a domain LocalizedError.

**Tests.** CoreDataErrorClassifierTests: out-of-space, CANTOPEN, IOERR, 257 and exhausted-timeout errors, both top-level and wrapped in NSUnderlyingErrorKey, map to a non-destructive action (Revert-check names the allow-list). Update the CoreDataRecoveryHandlerTests that currently pin exhausted-timeout -> .storeReset. CoreDataStackWaitTests: after a latched error, retryLoadAfterFailure reloads, and waitForStoreToLoad succeeds once the injected failure clears.

**Evidence.**
- `esc-chatmail/Services/CoreData/CoreDataErrorClassifier.swift:60` recommendedAction: retry, migrationRecovery, else storeReset
- `esc-chatmail/Services/CoreData/CoreDataRecoveryHandler.swift:71` createTimestampedBackup then removeStore
- `esc-chatmail/Services/CoreData/CoreDataStack.swift:214` reset then reload; :223 else setStoreLoadError
- `esc-chatmail/Services/CoreData/CoreDataStack.swift:125` lazy persistentContainer: load runs once per process
- `esc-chatmail/Services/CoreData/CoreDataRecoveryHandler.swift:90` CoreDataCriticalError posted, no observer
- `esc-chatmail/App/AppStartupBootstrap.swift:114` 1 s retry loop

**Caveats.** Which error a full disk actually raises at open was not verified on a device. On a non-APFS image, 40 KB free let the load succeed while saves failed with SQLite 13, and 0 bytes free failed with 256/14.

#### The attachment orphan sweep treats a failed Core Data fetch as 'no valid files' and deletes every attachment and preview

`attachment-orphan-sweep-fail-open` · ios · effort S

> Raised to will-break by the review: it permanently deletes the user's sent originals, the same reason the store-load ladder is a breaker.

**Problem.** performCleanupOrphanedFiles builds validFiles from every Attachment row and returns an empty Set when the fetch fails. The detached walk then removes every file in Attachments/ and Previews/ except live compose leases. Local non-inline originals (the user's sent files) are lost permanently. The HTML sweep returns nil and skips in the same situation. Separately, validFiles is a snapshot taken before the walk, so a download that lands in between can be swept.

**When it bites.** Rare trigger (an SQLite I/O fault during the nightly run); the damage scales with the store: multi-GB at S2 plus every sent-from-device original.

**What the user sees.** Every attachment turns back into a download placeholder, and the user's own sent photos and files are gone for good.

**Fix.** Return nil on fetch failure and skip the sweep, as the HTML sweep does. Build validFiles with a dictionary fetch of localURL/previewURL. Close the race by skipping files modified after the snapshot started, or by taking the snapshot after listing.

**Keep intact.** A failed Core Data read is never empty. Attachment-scoped paths can be shared by sibling messages. The sweep stays inside the exclusive run.

**Tests.** AttachmentOrphanSweepTests: an injected fetch failure leaves every file in place (Revert-check on the nil return); a file created after the snapshot survives.

**Evidence.**
- `esc-chatmail/Services/Attachments/AttachmentDownloader.swift:1278` return Set<String>() on failure
- `esc-chatmail/Services/Attachments/AttachmentDownloader.swift:1306` removes files not in validFiles
- `esc-chatmail/Services/DatabaseMaintenance/DatabaseMaintenanceService+Cleanup.swift:116` HTML sweep skips instead

**Caveats.** The loss is permanent, but the trigger is rare. Whether downloads can run during the maintenance run was not verified.

#### Initial-sync and history-recovery runs use one sync context that is never refreshed, so every message inserted in the run stays resident

`sync-context-retains-object-graph` · ios · effort M

**Problem.** InitialSyncOrchestrator.performSync builds one background context and reuses it for every 500-ID page; pageCompletion only rolls up and calls saveAsync, and history recovery behaves the same way. Nothing in Services/Sync calls reset() or refreshAllObjects() on the sync context. Inserted rows are wired in both directions through Label.messages, Person.messageParticipations, Message.participants and Conversation.messages, and the rollup prefetch realizes conversation.messages as well. After each save those realized inverse sets form strong cycles, so every Message of the run stays resident (bodyText, snippets, raw headers, participants, attachments) until the run ends. The PersonFactory cache pins only the Person objects and is not the cause.

**When it bites.** Triggered by a re-list since install: sign-out/sign-in, account switch or store reset on an old install, or a since-install history recovery. One run then holds about 470 MB+ at S2 and about 1.6 GB+ at S3, on top of 200-300 MB of caches. At S3 that is past foreground jetsam on most devices, and much earlier in any background run. A normal first-install initial sync and steady-state recovery hold tens of MB.

**What the user sees.** After signing back in on a mailbox several years old, the re-sync dies part-way through with no crash shown in the app. Each relaunch starts again from the top and can die at the same point. Meanwhile caches are evicted and the UI stutters.

**Fix.** At the orchestrator's own pageCompletion save points (initial sync and recovery), capture the page's inserted and updated Message, MessageParticipant, Attachment and Conversation objects before saving. Once saveAsync succeeds, call context.refresh(obj, mergeChanges: false) on each one without changes, inside context.perform. Do not call refreshAllObjects() every page: it re-faults the INBOX/system Label and self Person hubs, so the next page's first addToLabels or participant.person write refires a fault over all members so far, which is quadratic over an S3 re-list. A fallback is refreshAllObjects every K pages (K about 20). Do not use reset(). Ship together with initial-sync-window-anchored-to-install, which removes most of the trigger, and with initial-sync-no-durable-checkpoint, which stops a jetsam from restarting at page 1. The hub cost itself is fixed structurally in inverse-tomany-hub-fault-tax.

**Keep intact.** Only the orchestrator's own save points save the sync context; the refresh runs after the save and never saves. The failure ledger, counter checkpoint and Account cursor stage only into the final save, and pages must never carry staged state. Never refresh a context that holds unsaved staged changes. ModificationTracker commits and consumes on success and rolls back on every error path.

**Tests.** InitialSyncOrchestratorTests in .sqlite-mode TestCoreDataStack: across N synthetic pages, assert that non-fault registered Message objects stay bounded to about one page after each pageCompletion, with a Revert-check naming the post-save refresh. Add the same case for history recovery in IncrementalSyncOrchestratorTests. Add a --performance registered-object bound on a 50k-message SQLite fixture (an in-memory store cannot show this).

**Evidence.**
- `esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:97` single makeSyncContext() for the run
- `esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:328-345` pageCompletion: rollup + saveAsync, no refresh
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:689` history recovery, same single-context run
- `esc-chatmail/Services/Sync/CoreDataFactories.swift:290` participant.person / participant.message wiring
- `esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift:85` prefetch messages, labels, participants, person
- `esc-chatmail/Services/Sync/DataCleanupService.swift:267` precedent: refreshAllObjects + PersonFactory.resetCache

**Caveats.** The refute verifier rated this degrades because a first-install initial sync is tiny. It is breaks only for the re-list event, which is realistic on any long-lived install, because installTimestamp survives sign-out.

#### Initial sync has no durable progress; any kill, cancellation, BG expiry or abort restarts from page 1 and re-fetches every message

`initial-sync-no-durable-checkpoint` · ios · effort L

**Problem.** MessageIDPageStream.forEachPage starts with a nil pageToken and keeps the token only in memory. The only SyncCheckpoint kinds are foregroundHistory.v1 and syncFailureCounter.v1. BatchProcessor full-fetches every listed ID with no skip for rows that are already persisted. Account historyId is staged only in handleSyncCompletion, so a cancelled, killed, expired or aborted run leaves historyId nil, and the next trigger (the ~60 s foreground loop or a BGProcessingTask) runs the whole pass again. Failure-tainted completions escape after 3 strikes, but kills and cancellations never count as strikes.

**When it bites.** Only when initial sync is large, which means a re-list on an old install (see initial-sync-window-anchored-to-install). S1 (about 5-17 min) usually completes. S2 (1-2.5 h estimated) needs one uninterrupted foreground session. At S3 (3-8 h estimated) the pass essentially never completes: sync-context-retains-object-graph makes jetsam likely mid-run, each restart re-fetches the newest pages at 5 units per message, and no strike is ever counted.

**What the user sees.** Recent mail appears, but older mail stops at a different depth after each relaunch. Read, label and delete changes made elsewhere never sync, attachments are never scheduled, and the same data is downloaded over and over.

**Fix.** First bound the window (initial-sync-window-anchored-to-install), which is cheap and removes most of the exposure. Then add a SyncCheckpoint kind 'initialSync.v1' holding accountEmail, the first attempt's pre-scan startHistoryId, the query string and the messages.list pageToken; the existing entity fields are enough, so no schema change is needed. Stage it into the sync context inside each pageCompletion so it commits with that page. On the next run, resume when the account and query match, and discard the checkpoint on mismatch or on a rejected token. Clear it in the same final save that stages setAccountHistoryId, and at account teardown alongside clearContinuationState. Keep the first attempt's watermark so history from it covers label drift on earlier pages; if it has expired by completion, fall through to history recovery instead of advancing. Optionally skip format=full for IDs that are already durably persisted, using one indexed `id IN` dictionary fetch, but never skip IDs that previously failed. Share one store abstraction with history-recovery-no-checkpoint.

**Review correction (supersedes the fix above where they conflict).** Blocking-failure IDs accumulate in memory across pages and are recorded only in `handleSyncCompletion`. A run resumed from a staged page token would lose earlier pages' failures, and a clean tail could advance `historyId` past messages that were never stored. Store the accumulated `blockingFailureIds` and the frozen window start in `pendingMessageIdsJSON`, because `SyncCheckpoint` has no query column, and union them into the completion retry on resume. Compute the window once on the first attempt and reuse it from the checkpoint; a now-relative window would otherwise invalidate the checkpoint on every run. When listing completes but `historyId` is held, clear the checkpoint in that same final save. Add a "failure on page 1, kill, resume: cursor still frozen" test with a Revert-check.

**Keep intact.** Checkpoint stores stage into the caller's context, and only orchestrator save points save. Advance historyId only on shouldAdvance with a terminal listing. Cancellation propagates as a thrown error and is never a per-message verdict. Every attempted ID lands in exactly one MessagePersistDisposition bucket. Account teardown must clear the new kind.

**Tests.** Add InitialSyncCheckpointStoreTests, mirroring ForegroundHistoryCheckpointStoreTests. In IncrementalSyncCursorTests / SyncRunCoordinatorTests, add 'cancelled initial sync resumes from staged page token' and 'stale account checkpoint is discarded', each with a Revert-check naming the stage call in pageCompletion. In AuthSessionTests, assert teardown clears the kind.

**Evidence.**
- `esc-chatmail/Services/Sync/MessageListPaginator.swift:44` pageToken never persisted
- `esc-chatmail/Services/Sync/BatchProcessor.swift:47` every listed ID fetched, no existence filter
- `esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:423` historyId kept unset to retry
- `esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:465` setAccountHistoryId staged only at completion
- `esc-chatmail/Services/Config/Constants.swift:133` maxConsecutiveSyncFailures = 3
- `esc-chatmail/Services/Background/BackgroundSyncManager.swift:33` allowsExpensiveRecovery for .processing

**Caveats.** Raised from the theme's median of degrades: verifiers split (refute and fix lenses said degrades, the scale lens said breaks). The synthesis upgrades it because the writepath theme measured that an S3 re-list exceeds jetsam in one context, which, combined with no checkpoint and no strike on kills, becomes a restart loop.

#### History-expiry recovery falls back to the install timestamp, re-listing the whole mailbox, when lastSuccessfulSyncTime was cleared but the store and cursor were kept

`history-recovery-window-install-fallback` · ios · effort S

> Raised to will-break by the review: when it fires, it is the same since-install re-list, in a context that is never refreshed and cannot resume, as the initial-sync breaker.

**Problem.** `.historyRecovery` has maxWindow nil. When lastSuccessfulSyncTime is missing, its start time is install - 300 s, and the 7-day fallback applies only when install is also 0. clearAccountScopedSyncDefaults removes lastSuccessfulSyncTime on every teardown, including clearFailedGoogleSession, which keeps the local store. A same-account re-sign-in also keeps the store and its old Account.historyId. If that cursor has expired, the 404 sends performHistoryRecoverySync over every message since install.

**When it bites.** Triggered by a same-account re-sign-in after a rejected or revoked restore, once the retained historyId is older than Gmail's roughly one-week history retention. The pass then costs about 15k, 120k or 400k full GETs (at least 5 min, 40 min or 2.2 h at the quota cap) and about 4-12 GB downloaded at S2. Because recovery has no checkpoint, it effectively never finishes at S2/S3.

**What the user sees.** After re-authenticating, the app shows 'Recovering... x/y' with y equal to the whole mailbox, and new mail does not appear for hours.

**Fix.** Give `.historyRecovery` a real maxWindow, either recoveryFallbackWindow or 30 days, matching `.reconciliation`. Better: derive the lower bound from durable store state that commits with the cursor, such as the newest Message.internalDate (a fetchLimit-1 fetch on the indexed internalDate) minus a buffer, instead of a UserDefaults key that teardown clears independently. Keep the pre-scan watermark, and keep staging setAccountHistoryId only with the recovered rows.

**Review correction (supersedes the fix above where they conflict).** Do not set `.historyRecovery.maxWindow`. `Config.maxWindow` also caps the `lastSuccessfulSyncTime` branch (`SyncTimeCalculator.swift:87-91`), so every ordinary absence longer than N days would skip mail and advance the cursor past the gap. Do not bound it by the newest `Message.internalDate` either: recovery saves pages newest-first, and optimistic sends stamp a local `now`. Cap only the install branch, the one taken when `lastSuccessfulSyncTime` is missing. Derive that bound once, on the first attempt, from the newest received row (`isFromMe == NO`, fetchLimit 1; a failed read holds the run). Persist it in the recovery checkpoint and reuse it on resume.

**Keep intact.** The cursor moves only from the orchestrator's final save, and only when shouldAdvance is true. A failed newest-internalDate fetch must hold the run, never fall back to an unbounded window. Leave clearAccountScopedSyncDefaults' role in teardown unchanged.

**Tests.** IncrementalSyncCursorTests: recovery after a cleared lastSuccessfulSyncTime is bounded by maxWindow or by the newest stored internalDate. A SyncTimeCalculator unit test for .historyRecovery with install-only state. Revert-check naming Config.historyRecovery.maxWindow.

**Evidence.**
- `esc-chatmail/Services/Sync/SyncTimeCalculator.swift:42` .historyRecovery maxWindow nil
- `esc-chatmail/Services/Config/Constants.swift:209` recoveryFallbackWindow = 7 days (unreachable here)
- `esc-chatmail/Services/Security/AuthSession.swift:1842` removes lastSuccessfulSyncTimeKey
- `esc-chatmail/Services/Security/AuthSession.swift:1290` clearFailedGoogleSession keeps the store
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:694` recovery query

**Caveats.** The scale verifier rated this breaks; it stays degrades because it needs both a store-preserving teardown and an expired cursor. Throughput figures are estimates.

#### Web participant-set repair loads every message, participant and conversation into one 9-table rw transaction whenever its signature changes

`web-participant-repair-full-load` · web · effort L

**Problem.** runSync calls repairParticipantSetConversations before and after incremental sync. Its gate hashes the repair version, the alias set and every Hide-My-Email Person address. When the hash changes, it loads messages, msgParticipants, conversations, convoParticipants and outboundSends with unprojected toArray() calls (MessageRow carries uncapped bodyText), sorts every message, and puts every resident conversation, all inside one rw transaction on the main thread. The hash changes after an alias change, after any new HME correspondent, or when a deploy bumps PARTICIPANT_SET_REPAIR_VERSION. The signature is written only after the pass succeeds, so a tab killed by OOM replays the whole pass at the next sync.

**When it bites.** Fires whenever the signature changes, so on every new HME correspondent for Apple Hide-My-Email users and on every repair-version deploy. S1 is about 60-90 MB and a 1-3 s freeze. S2 is about 0.5-0.7 GB and a 10-30 s main-thread freeze, likely past the mobile WebContent limit, which turns into a reload and then a replay: a crash loop. At S3 (1.6-2.4 GB) it hits OOM on desktop too.

**What the user sees.** After an alias change, a new Hide My Email correspondent or an app update, the tab freezes for seconds to tens of seconds at the start of a sync. On phones the PWA reloads over and over.

**Fix.** Make the repair a streaming, chunked, resumable pass. (1) Find candidates through indexes: add an email index on convoParticipants (and msgParticipants if needed) in a new Dexie version, and look up only the addresses whose alias or HME classification changed. Walk conversations with a cursor only when a version bump truly needs a full sweep. (2) For each candidate, read [conversationId+internalDate] and the msgParticipants messageId index with projected fields only, and never keep bodyText. (3) Commit one conversation, or a small batch, per transaction, with a resumable progress cursor in syncState, and write the signature only after the last chunk. (4) Put a conversation only when its type or displayName actually changed. (5) Keep the per-conversation active-send deferral, which also withholds the signature.

**Keep intact.** Participant-hash identity stays canonical; never duplicate the hashing. Conversations named by an in-flight outbound send are excluded from re-homing (the web port of the iOS merge rule). Schema changes only through a new this.version(n). The pass runs only inside the per-account DB.

**Tests.** Extend the participantSetRepair vitest suite: an interrupted chunked pass resumes from the cursor and writes the signature only at the end; an unchanged conversation is not re-put; a conversation with an active send is skipped and the signature is withheld. Add Revert-check comments naming the progress cursor and the equality check.

**Evidence.**
- `web/src/sync/engine.ts:90` and :96 pre- and post-incremental repair calls
- `web/src/sync/participantSetRepair.ts:31` PARTICIPANT_SET_REPAIR_VERSION = 2
- `web/src/sync/participantSetRepair.ts:94-112` signature hashes HME Person addresses
- `web/src/sync/participantSetRepair.ts:233` one rw transaction over 9 tables
- `web/src/sync/participantSetRepair.ts:269-273` unprojected toArray of whole tables
- `web/src/sync/participantSetRepair.ts:613-615` signature written only on success

**Caveats.** The fix-feasibility verifier rated this degrades. The web store grows only from install time, so S2 takes years to reach.

#### Web history slices over 50 pages keep no continuation token, so a backlog is re-read and re-fetched every 60 s and never drains

`web-history-truncation-no-continuation` · web · effort M

**Problem.** collectHistory pages listHistory at Gmail's default 100 records per page, up to MAX_HISTORY_PAGES = 50. When it hits the cap it returns latestHistoryId = startHistoryId and wasTruncated = true, and drops the nextPageToken. Nothing persists a continuation and finalizeSync covers only messages, conversations and accounts. So every later sync restarts at the same cursor, re-reads the same 50 pages, re-fetches every messagesAdded ID with format=full without filtering stored IDs, and leaves lastSuccessfulSyncAt frozen. Records past page 50 are not reached until Gmail expires the history ID.

**When it bites.** When more than about 5,000 history records sit behind a valid cursor: an S2 user (300-500 records a day) away for 10-16 days, or a bulk archive or mark-read done in another client. From then on, every 60 s sync makes 50 history GETs and up to about 5,000 full message GETs (up to 25k quota units), for about a week, until history expires.

**What the user sees.** After a long absence or a bulk change in another client, read and archive state in the web app stops matching Gmail for days, sync spins constantly and gets 429-throttled, and mail from the gap is missing.

**Fix.** Mirror the iOS foreground history checkpoint. On truncation, stage {startHistoryId, nextPageToken} in syncState inside the same finalizeSync rw transaction (add syncState to it), without advancing Account.historyId. Resume from the token when the stored startHistoryId equals the cursor, and discard it otherwise. Advance only on a terminal slice (nextPageToken == nil) that shouldAdvanceHistoryId allows, and clear the continuation in that same transaction. If the page token is rejected (400/404), fall back to HistoryIdExpiredError recovery. Before phase 2, drop already-stored IDs with where('id').anyOf(ids).primaryKeys(), but still re-apply their label ops.

**Review correction (supersedes the fix above where they conflict).** Stage the continuation only when the slice would pass `shouldAdvanceHistoryId`, mirroring iOS, where a non-advancing slice moves neither the token nor the cursor. Staging past a slice with failed IDs skips those messages for good. On a rejected page token, clear the continuation in the same transaction and replay from the cursor, as iOS does (`IncrementalSyncOrchestrator.swift:258-276`). Do not jump to list recovery: a rejected token does not mean the cursor expired.

**Keep intact.** This is the web analogue of the iOS cursor rules: advance only on a terminal slice; a truncated slice stages the continuation and freezes the cursor; continuation, cursor and rollups commit together at the single finalize point; failures and cancellation never advance.

**Tests.** incremental.test.ts: update the truncation case to assert a staged continuation; add cases where the next run resumes and advances only on the terminal slice, where a mismatched startHistoryId discards the token, and where stored IDs are not re-fetched. Add Revert-check comments.

**Evidence.**
- `web/src/sync/incremental.ts:53` MAX_HISTORY_PAGES = 50
- `web/src/sync/incremental.ts:106-111` on cap returns startHistoryId, drops pageToken
- `web/src/sync/incremental.ts:359` fetches all history.newMessageIds, no stored-id filter
- `web/src/sync/incremental.ts:236` finalizeSync tables exclude syncState
- `web/src/sync/incremental.test.ts:298-314` pins 'keeps the ORIGINAL cursor when truncated'

**Caveats.** All verifiers agree on breaks. How long Gmail retains history (about a week or more) is Google's behaviour and was not measured.

#### Web HTML bodies and uncapped bodyText grow without retention, and a quota error inside the per-message apply transaction wedges sync

`web-body-storage-unbounded-quota-wedge` · web · effort L

> Raised to will-break by the review: once quota is hit, every sync fails until the user signs out.

**Problem.** applyMessagePlan writes the full HTML to db.bodies and the full plain text to MessageRow.bodyText, which is uncapped despite the type comment. Only server deletion, a SPAM/TRASH exclusion or journal moves ever delete rows, and only attachment blobs have a budget. A QuotaExceededError from bodies.put aborts that message's transaction, applyPersist has no catch, and every later sync replays the same history into the same full store.

**When it bites.** About 3.5-3.7 GB at S2 and 8-10 GB at S3 (estimated). Safari/iOS PWAs or low-disk phones hit quota around S1-S2, and every sync fails from then on.

**What the user sees.** Mail silently stops arriving and the list shows a raw quota error. Only signing out frees space.

**Fix.** (1) In a new Dexie version, add lastAccessAt to bodies (or key off internalDate), budget them against navigator.storage.estimate(), evict old archived-conversation HTML first, keep hasHtmlBody, and re-fetch lazily. (2) Cap bodyText to a prefix and fix the comment. (3) Catch quota errors around bodies.put, persist the message marked for re-fetch, evict outside the transaction and continue, and map hard failures to a typed, user-legible error.

**Review correction (supersedes the fix above where they conflict).** IndexedDB quota failures often surface as a transaction abort at commit rather than on the individual put. Catch at the transaction boundary, then re-apply the message without its body, marked for re-fetch, in a new transaction.

**Keep intact.** A body dropped for quota is explicitly marked re-fetchable, never silently complete with the cursor advanced. Eviction never touches rows of an in-flight outbound send. Schema changes go through a new Dexie version.

**Tests.** persist/incremental vitests: an injected QuotaExceededError completes the sync with the message stored and marked; budget eviction never evicts outbound rows and prefers archived ones; the bodyText cap truncates. Revert-check comments.

**Evidence.**
- `web/src/sync/persist.ts:868` bodies.put full HTML
- `web/src/sync/persist.ts:331` bodyText uncapped
- `web/src/db/types.ts:88` comment claims 'capped'
- `web/src/db/blobs.ts:81` budget covers blobs only
- `web/src/sync/engine.ts:98` raw error to lastError

**Caveats.** Hitting quota means a permanent wedge, which is breaks-like, but it is conditional on a constrained quota. Quota fractions are estimates.


## Will degrade

These do not lose data, but their cost grows with conversation size, mailbox size, or time, until the app is visibly slow, drains battery, or fills the disk.


### Sync engine and background budgets

#### Re-initial sync (sign-out/sign-in, store reset, missing historyId) re-lists and full-fetches every message since the original install

`initial-sync-window-anchored-to-install` · ios · effort M

**Problem.** buildInitialSyncQuery always uses `.initialSync` (maxWindow nil), so whenever installTimestamp > 0 the query is `after:(install-300s)`. The 30-day fallback applies only when install == 0, which FreshInstallHandler prevents except through the indeterminate-keychain backstop. AuthSession.clearAccountScopedSyncDefaults never clears installTimestamp, so every later initial sync covers the whole multi-year window that built the store. On a genuine first install the window holds about 5 minutes of mail. This is the trigger behind the re-sync will-break cluster.

**When it bites.** Triggered by an event at S2/S3. S2 costs about 120k full GETs (about 601k units, 40 min minimum at the quota cap, an estimated 1-2.5 h in practice). S3 costs about 400k GETs (about 2.0M units, 2.2 h minimum, an estimated 3-8 h).

**What the user sees.** After re-signing in on a long-lived install, mail fills in newest-first over hours with heavy battery and data use. Changes made elsewhere don't sync until the pass finishes.

**Fix.** Bound the re-initial-sync window independently of installTimestamp: start = max(install - buffer, now - N days), by giving `.initialSync` a maxWindow or by adding a config for re-sync on an existing install. If deeper history is wanted, backfill it as a separate, resumable, low-priority pass. Keep the pre-scan profile.historyId watermark and stage setAccountHistoryId only at the final save. Decide explicitly whether sign-out should reset installTimestamp, and record that decision as a why-comment in SyncTimeCalculator.

**Review correction (supersedes the fix above where they conflict).** Compute the bounded window once and freeze it into the initial-sync checkpoint; otherwise resume breaks (see the checkpoint item).

**Keep intact.** Only orchestrator save points save. historyId advances only through planHistoryAdvance from the pre-scan watermark. Any backfill pass is account-fenced and drained at teardown.

**Tests.** SyncTimeCalculator tests or IncrementalSyncCursorTests: an old installTimestamp yields a window capped at maxWindow. An InitialSyncOrchestrator query test with a Revert-check naming SyncTimeCalculator.Config.initialSync.maxWindow.

**Evidence.**
- `esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:288` buildSyncQuery(config: .initialSync)
- `esc-chatmail/Services/Sync/SyncTimeCalculator.swift:32` .initialSync maxWindow nil
- `esc-chatmail/Services/Sync/SyncTimeCalculator.swift:107` install branch wins before the fallback
- `esc-chatmail/Services/Security/AuthSession.swift:1839` clearAccountScopedSyncDefaults leaves installTimestamp
- `esc-chatmail/Services/Sync/MessageFetcher.swift:154` getMessage(format: full) per listed ID

**Caveats.** Whether a returning same-account user should get the full since-install re-pull is a product decision; for a different account it is plainly wasted. Throughput figures are estimates.

#### History recovery is one uncapped, non-resumable pass; every interruption or held attempt re-fetches the whole window

`history-recovery-no-checkpoint` · ios · effort M

**Problem.** performHistoryRecoverySync saves each listed page, but writes no page-token continuation, and setAccountHistoryId moves only after the whole listing finishes. lastSuccessfulSyncTime is written only on a terminal clean commit. So a cancelled, thrown or held attempt leaves the expired cursor in place; the next sync 404s, re-lists the same window and re-GETs (format=full) every message already saved. Held attempts escape after 3 strikes, but cancellations count none.

**When it bites.** Cost scales with how long the user was away, not with store size. A two-week absence means about 600, 1.5k and 3k GETs per attempt at S1, S2 and S3, which usually completes. A two-month absence at S3 is about 13k GETs (0.5-1 GB) per attempt, and every killed attempt repeats it.

**What the user sees.** After a long absence, 'Recovering... 0/N' restarts on every app open, and the same messages download again.

**Fix.** Persist a 'historyRecovery.v1' SyncCheckpoint (account, query, the first attempt's pre-scan watermark, list pageToken), staged in the same pageCompletion save as the page. Resume when the query and account match. Clear it in the final save that stages the new cursor, and at teardown. No schema change is needed. Share the store abstraction with initial-sync-no-durable-checkpoint, and cap the window (history-recovery-window-install-fallback). Optionally skip full GETs for IDs that are already present.

**Review correction (supersedes the fix above where they conflict).** Same failure-ID problem as initial sync. Carry the accumulated failure IDs and the frozen window start in the `historyRecovery.v1` payload and merge them before `planHistoryAdvance`.

**Keep intact.** Checkpoint stores stage into the caller's context. Resumed pages influence advancement only through planHistoryAdvance. Cancellation is thrown. BackgroundSyncManager never writes cursors itself. Keep clearContinuationState at teardown.

**Tests.** Add HistoryRecoveryCheckpointStoreTests. IncrementalSyncCursorTests: 'cancelled recovery resumes from staged page token without re-fetching saved pages' and 'recovery checkpoint cleared in the advancing save', each with a Revert-check.

**Evidence.**
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:715` recovery listing
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:792` stageClear then setAccountHistoryId only at end
- `esc-chatmail/Services/Sync/MessageListPaginator.swift:47` token held in memory only
- `esc-chatmail/Services/Sync/SyncFailureTracker.swift:320` lastSuccessfulSyncTime only on resolved success

**Caveats.** All verifiers rated this degrades. The design shares its checkpoint shape and its skip-existing optimization with the initial-sync item.

#### Message-get 429s have no shared pacing; exhausted rate-limited IDs become blocking failures that hold the cursor and can force another full pass

`rate-limit-pacing` · ios · effort M

**Problem.** MessageFetcher calls getMessage with maxRetries 1, so the client throws on a 429 before it ever calls rateLimitTracker.recordBackoff. That ordering is deliberate: N concurrent 429s must not trip the 120 s breaker when nobody actually waited. All backoff therefore lives in fetchBatch: 3 retries per 50-ID batch (0.5/1/2 s, or a Retry-After capped at 60 s), each fanning out again at 15-way concurrency with no shared limiter. IDs still limited on the last pass become blocking failures. On initial sync, the ones that survive the completion retry leave historyId unset and force another full pass.

**When it bites.** During large passes (re-initial sync or a long recovery at S2/S3), 15 concurrent GETs burst to 50-100 requests/s, or 250-500 units/s, against a per-user cap of about 250 units/s. The 3.5-4.5 s retry ladder is shorter than a typical per-user recovery period. Each exhaustion can cost another full pass.

**What the user sees.** 'Sync completed with warnings', then initial sync starts over.

**Fix.** Add a separate shared, time-decaying limiter (a token bucket sized to Gmail's per-user unit rate, with AIMD on 429) used by MessageFetcher, so concurrency backs off globally after a 429. Do not route maxRetries-1 429s into RateLimitTracker's breaker. Lengthen the ladder for 429s specifically, to 30-60 s in total. Keep rateLimited as a per-message verdict.

**Keep intact.** isAccountScopedSyncAbort covers auth, revoked credentials and quota only. Cancellation throws. messages.send stays off every retrying path; the limiter may pace a send only before the transmission barrier and never retries it. Test retries against the real GmailAPIClient through StubURLProtocol with FakeSyncClock.

**Tests.** MessageFetcher retry tests using the real GmailAPIClient, StubURLProtocol and FakeSyncClock: 'sustained 429 reduces in-flight concurrency' and '429 ladder outlasts a 10 s limit window', each with a Revert-check naming the limiter acquire.

**Evidence.**
- `esc-chatmail/Services/API/GmailAPIClient.swift:391` only delays actually slept are recorded
- `esc-chatmail/Services/API/GmailAPIClient.swift:407` throw before recordBackoff at maxRetries 1
- `esc-chatmail/Services/Sync/MessageFetcher.swift:61` maxRetryAttempts = 3, 500 ms base
- `esc-chatmail/Services/Config/Constants.swift:117` maxConcurrentMessageFetches = 15

**Caveats.** The scale lens rated this hygiene, because a fresh install's initial sync is tiny. The completion retry recovers many transient failures minutes later.

#### Initial-sync completion retry fetches and prepares all failed IDs in one fetchBatch, holding every refetched message in memory

`completion-retry-unchunked` · ios · effort S

**Problem.** handleSyncCompletion passes every blocking failure ID, accumulated across all pages, to retryFailedMessages. That calls fetchBatch once, with no chunking. Every format=full message lands in one array, which one saveMessages call then prepares in full before persisting. A jetsam at this point discards the whole run, because the cursor commits after this phase.

**When it bites.** Only on a large re-initial sync with a failure storm. At a 1% failure rate, S2 retries about 1.2k IDs (about 25-180 MB) and S3 about 4k (80-600 MB). A 10% rate-limit episode at S3 (about 40k IDs) runs out of memory. All figures are estimates.

**What the user sees.** A memory spike or crash at the very end of a long initial sync, which then restarts from page 1.

**Fix.** Chunk inside retryFailedMessages by SyncConfig.messageBatchSize, merging MessageBatchOutcome and MessagePersistenceReport per chunk. Keep the one-bucket-per-ID partition, let account-scoped aborts propagate mid-loop without verdicts for the remainder, and keep chronological order within each chunk.

**Keep intact.** Every attempted ID lands in exactly one disposition bucket. Account-scoped aborts put IDs in no bucket and rethrow. saveMessages receives chronologically sorted input.

**Tests.** MessagePersisterDispositionTests or a BatchProcessor test: 'completion retry of 120 IDs fetches in 50-ID chunks and partitions every ID once' and 'quota abort mid-chunk leaves remaining IDs unclassified', with a Revert-check naming chunked(into:).

**Evidence.**
- `esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:372` retryFailedMessages(all blocking IDs)
- `esc-chatmail/Services/Sync/BatchProcessor.swift:93` fetchBatch(failedIds) unchunked
- `esc-chatmail/Services/Sync/MessageFetcher.swift:179` successfulMessages.append

**Caveats.** An ID reaches this retry only after four failed attempts inside its own batch, so realistic counts are small outside sustained 429 storms. The fix is cheap regardless.

#### BGAppRefresh slices still run reconciliation, the abandoned drain, missed-message recovery and due maintenance passes, and an expired slice commits nothing

`bg-app-refresh-budget-not-honored` · ios · effort M

**Problem.** The background budget reaches only historyPageLimit, historyPageSize and allowsExpensiveRecovery. An app-refresh slice (3x100 records) therefore still runs the abandoned drain (up to 50 full fetches), the missed-message check (up to 500 IDs) and TTL-gated label reconciliation. That TTL is 20 min against a refresh cadence of 15 min or more, and the reconciliation time is recorded only after a committed save. When the 6 h cadence is due, the slice also runs the nine store-wide maintenance passes, which can only be cancelled between passes. The checkpoint and cursor commit only at the final save and persisted IDs are not skipped, so an expired slice repeats all of this on the next refresh, and BackgroundTaskCompletionLatch delays setTaskCompleted until the current pass finishes.

**When it bites.** S2/S3 after days offline or newsletter bursts. A worst-case slice is about 300 full fetches (about 10 s), up to 50 drain fetches and about 101 reconciliation calls, against a refresh window of about 30 s, plus seconds of maintenance at S3 when the cadence is due (estimated).

**What the user sees.** Background refreshes burn battery and quota without making progress, iOS throttles them over time, and the app opens with stale chats.

**Fix.** Thread an allowsStoreWideMaintenance / expensive-work flag from the budget into the orchestrator and runIncrementalCleanup. Under .appRefresh, skip label reconciliation, the abandoned drain, missed-message recovery and the cadence-gated maintenance passes, leaving the cadence unmarked so foreground or processing runs pick them up. Optionally shrink the slice after an expiry. Optionally skip re-fetching history IDs whose row already exists, still counting them in exactly one bucket (persisted). Do not add an early checkpoint save. If maintenance moves to StoreMaintenanceCoordinator (six-hour-maintenance-inside-sync-run), start it only from foreground or BGProcessing.

**Review correction (supersedes the fix above where they conflict).** Keep the single missed-message list call under `.appRefresh`; it is documented as the cheap per-sync safety net against dropped history events. Defer only the fetching of the IDs it finds. If you skip history IDs whose row already exists, exempt IDs named by live `OutboundSendMutationRecord`s, because the update path is where send echoes are consumed.

**Keep intact.** Background sync uses the same executor and cursor rules, and BackgroundSyncManager never writes cursors. Checkpoint, ledger and cursor commit together. The drain alone owns retryCount, and drain failures never influence the cursor. Cancellation is thrown, never recorded as a verdict.

**Tests.** IncrementalSyncCursorTests / BackgroundSyncManagerTests: an appRefresh run skips reconciliation, the drain and maintenance, leaves the cadence due, and leaves cursor and checkpoint unchanged on cancellation. AbandonedMessageRetryTests: the drain still runs on processing and foreground budgets. Revert-check naming the budget guard.

**Evidence.**
- `esc-chatmail/Services/Config/Constants.swift:107` maxHistoryPagesPerAppRefreshSlice = 3
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:316` abandoned drain every slice
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:378` TTL-gated label reconciliation
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:423` checkpoint staged late
- `esc-chatmail/Services/Sync/DataCleanupService.swift:149` cadence gate, no budget parameter
- `esc-chatmail/Services/Background/BackgroundTaskCompletionLatch.swift:41` waits for unwind

**Caveats.** Merges the memory BG-slice item with the maintenance BG-refresh item. Whether real refreshes expire depends on the window iOS grants, and how long iOS tolerates an overrun was not measured.

#### History label and deletion processing does a context.perform, about 4 SQL statements and 2-3 actor hops per record instead of per slice

`label-ops-unbatched-per-record` · ios · effort M

**Problem.** LabelProcessingPhase awaits processLightweightOperations for each HistoryRecord in sequence. Each non-empty change list opens its own perform with an indexed `id IN` fetch, labels and conversation prefetches and a Label fetch, then awaits ModificationTracker.trackModifiedConversations even when nothing changed. Records are batched within themselves but never across a slice.

**When it bites.** During catch-up after an absence, independent of store size. A full 5,000-record slice takes about 1.5-8 s of background time, and a two-week, 20k-record backlog about 10-30 s (estimated).

**What the user sees.** Catching up after a few days away takes noticeably longer than the download alone.

**Fix.** Collect the slice's message IDs into one indexed `id IN` fetch with labels and conversation prefetched, load the Label table once, apply the records in order in memory inside one perform (skipping messages a previous record deleted), and call ModificationTracker once with a Set, skipping the hop when it is empty. Order, throwing semantics and cancellation checks stay the same.

**Keep intact.** No saves inside the phase. Cancellation propagates as a thrown error. Account-scoped aborts stay run-level. Every touched conversation is tracked.

**Tests.** HistoryProcessorTests / HistoryMutationFailureTests: a mixed slice (add, remove, delete, re-add on the same message) produces the same end state as per-record processing, and an injected fetch failure still throws. Revert-check naming the slice prefetch. Run IncrementalSyncCursorTests.

**Evidence.**
- `esc-chatmail/Services/Sync/Phases/LabelProcessingPhase.swift:28-37` per-record await loop
- `esc-chatmail/Services/Sync/LabelOperationProcessor.swift:64-79` per-call perform + fetches
- `esc-chatmail/Services/Sync/HistoryProcessor+MessageDeletions.swift:18` per-record deletion perform

**Caveats.** The refute verifier rated this hygiene, because typical records carry a single change and cost under 1 ms each.

#### One destructive record anywhere in a history slice disables every intermediate save for the whole slice

`no-intermediate-saves-destructive-slice` · ios · effort M

**Problem.** allowsIntermediateContextSaves(for:) is computed once per slice. It returns false if any record deletes messages, adds a message with nil labelIds, or adds SPAM, TRASH or DRAFT. When it is false, both the per-50-message batch save and the post-label flush are skipped, so every row the slice persists stays dirty in one context until a single final save. That save then merges into the auto-merging viewContext. In a multi-day catch-up, at least one delete or trash is near-certain.

**When it bites.** Catch-up slices of 1k-3k new messages hold an estimated 50-200 MB dirty set until one multi-second transaction lands, followed by a large main-queue merge. Steady state is negligible, and BGAppRefresh slices are capped at 3x100 records.

**What the user sees.** During catch-up, memory spikes, nothing appears until the whole slice lands, and the large merge hitches the UI.

**Fix.** Keep the safety reason: a partial save must not expose a message that a later record deletes or excludes. Narrow it by computing the slice's set of deleted or excluded IDs and allowing batch saves for messages outside that set. Alternatively apply local deletions and exclusions first, then fetch with batch saves on. The cheapest fallback is a smaller page budget (for example 3 pages) when the flag is false. The cursor, continuation, ledger and counter still stage only into the final save.

**Keep intact.** Only orchestrator save points save. Checkpoint, ledger and cursor commit together in the final save. The cursor advances only on shouldAdvance with a terminal slice. Each ID lands in exactly one disposition bucket, and persistence stays sequential and chronological.

**Tests.** IncrementalSyncOrchestratorTests: a slice that deletes message A and adds 200 unrelated messages performs intermediate saves, and A is never visible in a saved state. Revert-check naming the narrowed predicate. Run IncrementalSyncCursorTests, SyncFailureTrackerEscapeHatchTests and ForegroundHistoryCheckpointStoreTests unchanged.

**Evidence.**
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:947-966` allowsIntermediateContextSaves
- `esc-chatmail/Services/Sync/Phases/MessageFetchPhase.swift:53-58` batchCompletion returns before saving
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:335-369` flush deferred

**Caveats.** The fix verifier considers the memory figure overstated. The cost compounds with the hub-fault and rollup items in the same context.


### Per-message write path and rollups

#### Any message write in a fresh context fires mailbox-sized inverse to-many faults on the system Labels and the self Person

`inverse-tomany-hub-fault-tax` · ios · effort XL

**Problem.** Message.labels <-> Label.messages is a Nullify many-to-many with an inverse, and MessageParticipant.person <-> Person.messageParticipations is a to-one/to-many pair. addToLabels and removeFromLabels go through mutableSetValue(forKey: labels), so Core Data's inverse maintenance materializes the whole Label.messages set for INBOX, UNREAD, IMPORTANT and CATEGORY_*. Setting participant.person does the same to the self Person, because saveParticipants never excludes the owner, and deleting a Message fires all of these plus Conversation.messages. The cost is paid once per hub per context, and every incremental run, BGTask run and cleanup pass builds a fresh context, so even a 1-message sync pays O(INBOX + UNREAD + category membership + all messages) in registered objects.

**When it bites.** Every sync run that inserts, relabels or deletes even one message at S2/S3, including push and BGAppRefresh runs. At S3 one new message costs 1,238 ms, 740k registered objects and +172 MB; one delete costs 634 ms (924 ms in a list conversation). At S2 one new message costs 100 ms warm or 3.8 s cold, +49 MB. All measured on an M5 Pro; S1 is about 1/25 of S3.

**What the user sees.** Every sync, however small, gets slower and heavier as the mailbox ages. Push-to-display latency grows by hundreds of ms, background refresh uses more battery, and the +50-170 MB transient raises jetsam risk in BGTask windows.

**Fix.** The structural fix belongs in the single ESCChatmail 7 model version (a new directory plus the .xccurrentversion bump; v6 stays untouched). (a) Denormalize system-label membership into indexed Message attributes (isInInbox, isSent, isSpam, isTrash, isDraft, isStarred, isImportant, plus a category enum), keep the Label many-to-many only for user labels, and rewrite `ANY labels.id == INBOX` and the excluded-label SUBQUERY through MessagePredicates. (b) Remove inverse maintenance for the self-Person edge without dropping self MessageParticipant rows: either an inverse-less MessageParticipant.person, with explicit Person merge and orphan cleanup, or a kind+email self row with no person link. Measure first with the SQLite scale harness: a 1-message persist and a 1-message delete through the real persister on a fresh context over a 100k store. Until v7 ships, keep label mutations off the viewContext (archive-spam-star-main-thread-viewcontext).

**Keep intact.** Versioned xcdatamodel only, never mutate the loaded model, and never edit v6. Message.strictParticipantSetIdentity needs complete From/To/Cc rows, where nil means do not re-home, so self MessageParticipant rows must stay. Optional migrated attributes can hold NULL, so filters need an `== nil` disjunct. participantHash stays canonical. Keep MessagePredicatesSQLiteTests parity.

**Tests.** Add an opt-in Performance.xctestplan case in .sqlite mode: after a 1-message persist, relabel and delete, hasFault(forRelationshipNamed:) is still true on the INBOX Label's messages and the self Person's messageParticipations, with a Revert-check naming the v7 path. Add v6->v7 backfill migration tests (RecipientHeadersV6MigrationTests pattern). Extend MessagePredicatesSQLiteTests, DuplicateLabelMergeTests and the Person merge/orphan tests.

**Evidence.**
- `esc-chatmail/Services/CoreData/ManagedObjects.swift:148-156` addToLabels/removeFromLabels via mutableSetValue
- `esc-chatmail/Services/Sync/Persistence/MessagePersister+Creation.swift:147` addToLabels per new message
- `esc-chatmail/Services/Sync/CoreDataFactories.swift:290` participant.person = person (self included)
- `esc-chatmail/Services/Sync/HistoryProcessor+MessageDeletions.swift:33` context.delete(message)
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:206` fresh sync context per run
- `esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld/ESCChatmail 6.xcdatamodel/contents:83` and :149 Label.messages / Message.labels

**Caveats.** Magnitudes differ about 10x between harnesses: 1.2-1.4 s on the real model versus 16-114 ms in minimal -O harnesses. Five auditors reproduced the mechanism.

#### Every rollup loads every message of each touched conversation as a full row with its label joins, and incremental sync does it twice per run

`rollup-full-conversation-materialization` · ios · effort L

**Problem.** updateRollupsForModified fetches the touched conversations and prefetches messages, messages.labels, participants and persons, with no limit and no propertiesToFetch. It then hands the whole conversation.messages set to ConversationRollupSnapshot.make (which builds a label Set per message), and headerDisplayNamesByEmail walks it again. That is O(lifetime messages) full rows, inline bodyText included, however few changed. Initial sync re-rolls a dominant list on nearly every page, and incremental sync rolls up modifiedConversations at the intermediate flush and again at finalize.

**When it bites.** Scales with the largest conversation a sync touches. A 20k list chat measured 174-186 ms and +166-182 MB per rollup (M5 Pro), roughly 2-3x on iPhone, on every sync that touches it. A 1-3k chat at S2 costs an estimated 0.2-0.8 s and 5-25 MB per rollup, twice per incremental run. A 10-message conversation costs 11-17 ms.

**What the user sees.** Sync slows as big newsletter and notification chats age, background refresh spikes memory, and new mail appears late in the list.

**Fix.** Keep ConversationRollupSnapshot as the single definition and keep the serializer block; change only how its inputs are gathered. Use bounded managed-object queries over byConversationAndDateIndex: the newest visible message (fetchLimit 1), a count of INBOX AND isUnread, the newest INBOX message, and fetchLimit-1 existence probes for hasSentOrFromMe and hasReceived. Overlay the context's dirty Messages for that conversation, because rollups run before the save. Do not use dictionary or propertiesToFetch fetches for these inputs: they ignore pending changes, and fetchLimit-1 can return zero rows when a dirty row no longer matches, so re-select from stored candidates plus dirty objects. Feed header names from a narrow sender-field query. In incremental sync, claim IDs at the intermediate flush. Use the v7 system-label flags once they exist.

**Review correction (supersedes the fix above where they conflict).** The bounded inputs must also cover `latestVisiblePreviewMessage`, which sources `Conversation.snippet`: the newest visible message whose computed `conversationPreviewText` is non-empty. SQL cannot express that, and the row can be older than the newest visible message. Add a newest-first walk with a small `fetchBatchSize` that stops at the first non-empty preview, with the dirty-object overlay. Add parity tests where the newest message has a blank preview.

**Keep intact.** Recompute and save inside one performThrowingSyncMutation block keyed on the affected IDs, with no new save points. List titles are never sender-derived except updateDisplayNameOnly's single-distinct-sender upgrade, whose semantics must not change. No raw SQL. Query through MessagePredicates. Keep the equal-value-write skip.

**Tests.** ConversationRollupUpdaterTests parity: old full walk versus bounded inputs over the golden corpus and seeded .sqlite conversations, including unsaved inserts, unsaved INBOX removals, unsaved deletes and excluded-label rows, with a Revert-check naming the dirty overlay. ConversationRollupMutationSerializerTests, an IncrementalSyncOrchestratorTests case for no double rollup, and a --performance 20k-conversation rollup case.

**Evidence.**
- `esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift:83-90` SELF IN fetch with 4-path prefetch
- `esc-chatmail/Services/Conversation/ConversationRollupSnapshot.swift:19-72` walks every message
- `esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift:652` second walk for header names
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:336-363` intermediate flush does not claim
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:461-466` finalize rolls up again

**Caveats.** The quadratic initial-sync form applies only to a re-list. The second incremental rollup reuses rows already in the context, so its real cost is the in-memory walk.

#### Every history item that removes INBOX walks the whole conversation, faulting labels one message at a time, and the run's rollup then overwrites the result

`label-op-inbox-refresh-conversation-walk` · ios · effort S

**Problem.** LabelProcessingPhase processes one HistoryRecord at a time. When a message leaves INBOX, applyFastInboxIndicators calls refreshInboxIndicators, which iterates all of conversation.messages and reads each one's labels. Labels are prefetched only for the touched IDs, so the first walk faults siblings' labels individually, and every later removal in the same conversation repeats the O(n) walk, giving O(k*n) per run. The values are never saved before ConversationRollupUpdater overwrites hasInbox, inboxUnreadCount and latestInboxDate, and MessagePersister.refreshConversationInboxIndicators repeats the pattern on the update path.

**When it bites.** Triggered at S2/S3 by a bulk archive in another client. 500 removals in a 2k-message chat cost about 1M label-set scans plus 1.5k fault queries, 1-3 s; a 10k chat costs about 5x that (estimated). A single archive costs O(n).

**What the user sees.** After bulk-archiving in Gmail web, sync takes many seconds and archived chats linger in the list.

**Fix.** Drop refreshInboxIndicators from the per-record path and keep the O(1) unread-count delta. The exact values come from the rollup that already runs inside the serializer before every save that persists the change. If a mid-slice value is needed, compute it once per conversation after all records, with labels batch-prefetched or with count/fetchLimit-1 queries. Apply the same change to MessagePersister.refreshConversationInboxIndicators. The writepath theme checked that no mid-slice reader routes on conversation.hasInbox.

**Keep intact.** Rollups recompute and save inside one ConversationRollupMutationSerializer block. No new save points. Every touched conversation is still tracked in ModificationTracker.

**Tests.** HistoryProcessorTests / IncrementalSyncOrchestratorTests: many INBOX removals in one large conversation leave correct rollup values after the final save, and siblings' label sets are not faulted per record. Revert-check naming the removed call. Run IncrementalSyncCursorTests unchanged.

**Evidence.**
- `esc-chatmail/Services/Sync/LabelOperationProcessor.swift:210` refreshInboxIndicators per INBOX removal
- `esc-chatmail/Services/Sync/LabelOperationProcessor.swift:215-247` walks conversation.messages + labels
- `esc-chatmail/Services/Sync/LabelOperationProcessor.swift:68` labels prefetched only for touched IDs
- `esc-chatmail/Services/Sync/Persistence/MessagePersister+Helpers.swift:723` update-path O(n) prefetch per call

**Caveats.** Merges the memory and writepath items. Timings are estimates.

#### Consuming a send echo recomputes the conversation rollup over every message with no labels prefetch

`send-echo-rollup-unprefetched` · ios · effort S

**Problem.** consumeRemoteCommittedSendMutation runs for every synced echo that still has a live optimistic row, which is the normal path. After deleting the superseded row, it runs ConversationRollupSnapshot.make(from: conversation.messages), which faults each message's labels individually, about n+1 queries. The page or final rollup recomputes the same conversation with a prefetch before the same save, so this work is redundant.

**When it bites.** Paid for the first echo per conversation per context. A 2-3k chat at S2 costs about 0.3-0.7 s and a 5-10k chat at S3 about 0.5-2 s, on the sync queue during the sequential persist (estimated).

**What the user sees.** After sending in a long-running chat, the next sync stalls in persistence, delaying convergence of the echo.

**Fix.** The inline snapshot is needed only to decide whether a newly inserted conversation is now empty and should be deleted. Answer that with count(for:) at fetchLimit 1 on `conversation == %@ AND NOT (SELF IN deletedObjectIDs)` and skip make().apply, since the conversation is already tracked for the serializer rollup. Otherwise register it with MessagePersisterReroutedSourceRollupBuffer, whose drainAndApply prefetches labels. Keep the ChatReplyDraft anchor check, the deletion and the record consumption in the same save as the echo.

**Keep intact.** Sync owns atomic replacement and record consumption (consumeRemoteCommittedSendMutation) inside the transaction that persists the echo. Conversations with a saved draft or an in-flight record are never deleted. Rollups happen inside the serializer block.

**Tests.** Echo tests in MessagePersisterDispositionTests: a newly inserted conversation is still deleted when its only message was the superseded row, is kept when it has a draft, and gets a correct rollup after the page rollup. Revert-check naming the replaced make(from:). Re-run GmailSendServiceOptimisticFailureTests.

**Evidence.**
- `esc-chatmail/Services/Sync/Persistence/MessagePersister+Helpers.swift:384-388` inline make(from:)
- `esc-chatmail/Services/Sync/Persistence/MessagePersister+Creation.swift:191` called from createNewMessage

**Caveats.** Query count corrected to n+1. The unbuffered reroute half was shown to be a dead path.

#### Non-INBOX mail to an archived participant set mints a new conversation epoch per sync run that is archived immediately (iOS and web parity)

`non-inbox-arrival-epoch-growth` · both · effort L

**Problem.** shouldReactivateArchivedConversation is true only for INBOX, SENT and from-me mail. Skip-inbox filter mail, and mail archived elsewhere before sync, therefore mints a new shell when no active epoch exists, and the rollup archives it immediately; the rate is about one epoch per sync run that carries the sender. The candidate lookup fetches every epoch of the hash with no archivedAt predicate or limit. The web port has the same semantics, deliberately in parity.

**When it bites.** For users with skip-inbox filters at S2/S3, 20 daily filtered senders add about 7.3k Conversation rows a year, about 22k by S2 and 36k by S3 (estimated), which inflates every whole-store conversation pass.

**What the user sees.** Mostly invisible. Whole-store passes slow down, and a filtered list's history is spread across thousands of single-message archived chats.

**Fix.** (1) Now, with no behaviour change: query archivedAt == nil with fetchLimit 1 first, and fetch the newest archived epoch (sorted, fetchLimit 1) only when reactivation is allowed. On the web, use the [participantHash+isArchived+lastMessageDate] index with reverse().first(). (2) Product decision for both platforms together: route a filtered arrival into the newest archived epoch without reactivating it, or add a maintenance fold of consecutive archived epochs. Update the pinned tests deliberately.

**Review correction (supersedes the fix above where they conflict).** "Active first, fetchLimit 1" changes which conversation is picked: duplicate active epochs exist (that is why `mergeActiveConversationDuplicates` exists), and recency is `lastMessageDate ?? latestInboxDate ?? archivedAt`, which no single sort descriptor expresses. Fetch the active rows unlimited (they are few) and apply the existing policy. For archived epochs, run a dictionary fetch of objectID plus the three dates only when reactivation is allowed, and pick the winner in memory.

**Keep intact.** New-arrival epoch semantics differ deliberately from repair semantics (existingConversationObjectID), so changing them is a product decision. Any fold excludes in-flight send-record conversations. l| titles are never sender-derived. participantHash stays canonical, and iOS and web must stay in parity.

**Tests.** MessageConversationRouterListTests and the participant-hash router tests for the active-first limited lookup; a web routing vitest with many archived epochs; ConversationMerger tests if a fold is added.

**Evidence.**
- `esc-chatmail/Services/Conversation/ConversationRoutingPolicy.swift:14` reactivation rule
- `esc-chatmail/Services/Conversation/ConversationCreationSerializer.swift:47` lookup with no archivedAt predicate or limit
- `esc-chatmailTests/Sync/MessageConversationRouterListTests.swift:158` behaviour pinned
- `web/src/identity/routing.ts:88` candidate scan over all epochs

**Caveats.** Merges the iOS memory item (degrades) with the web hygiene item. Growth depends entirely on skip-inbox volume; category tabs keep INBOX.


### Main-thread UI hot paths

#### Archive, Report Spam and star mutate labels on the main-thread viewContext, walking the whole conversation and faulting the whole INBOX membership

`archive-spam-star-main-thread-viewcontext` · ios · effort M

**Problem.** MessageActions is @MainActor. archive(message:), archiveConversation(s), reportSpamConversation(s) and star/unstar all mutate labels on coreDataStack.viewContext. The conversation variants walk conversation.messages with no prefetch, paying about 2 round trips per message (row fault plus labels fault, confirmed with SQLDebug) and then a main-thread save of N dirty rows, where N counts lifetime messages summed over the selection. Any removeFromLabels/addToLabels also fires the INBOX (or SPAM/STARRED) Label.messages inverse fault in the viewContext, registering every member, and those objects can stay registered, slowing later merges (64.6 ms versus 1-16 ms). Unlike the read-state paths, none of this goes through ConversationRollupMutationSerializer.

**When it bites.** Conversation walk: negligible at S1. At S2/S3 a 1-2k-message chat costs about 0.3-1.5 s on main; a 19-20k chat measured 5.6 s (S2) and 11.7 s (S3) with +207-237 MB in a private-context replay, 2-3x slower on iPhone. INBOX fault on any archive: 0.12 s at S2 and about 0.4 s at S3 (314k members) even for a 10-message chat, plus 20-70 MB retained.

**What the user sees.** Swipe-to-archive, multi-select archive or Archive/Report Spam from a long chat freezes the UI for up to seconds. The first archive after launch hitches even on a short chat, and memory stays elevated.

**Fix.** Move all of these mutations to coreDataStack.newBackgroundContext() inside rollupMutationSerializer.perform(conversationKeys:), under the existing non-exclusive lease, re-checking isActiveRun after every suspension, as performMarkMessagesAsReadBatch does. Pass NSManagedObjectIDs. Fetch messages with `conversation == %@`, relationshipKeyPathsForPrefetching [labels] and a fetchBatchSize. Keep stamping localModifiedAt on every row and keep addToLabels(SPAM) on every row; only the archive's removeFromLabels may skip rows that lack INBOX. Set archivedAt and the inbox rollup in the same save (applyArchivedConversationRollup), keep the list's instant response as an optimistic hide in the view model, and let the context go (or reset it) after the save so the faulted INBOX set does not outlive the action. The per-action background INBOX fault only goes away with inverse-tomany-hub-fault-tax.

**Keep intact.** Lease rules: never wait on the exclusive boundary while holding the lease, and re-check isActiveRun after suspensions. Managed objects never cross contexts. Use newBackgroundContext() so the merge policy is set. Save via saveOrLog or performSaveIfNeeded. archivedAt semantics stay: future mail opens a new conversation. Keep the optimistic-ID exclusion from Gmail payloads, and keep ChatConversationExitActionPolicy's deferral until the optimistic row is durable.

**Tests.** MessageActionsTests: background-context archive and spam leave every message INBOX-free (and SPAM-labelled for spam), stamp localModifiedAt on every row, set archivedAt and exclude optimistic IDs. After archive(message:), the viewContext's INBOX Label is not registered, or its messages relationship is still a fault. A stale-lease case (account closed mid-mutation) writes nothing. Use stack.makeMainQueueViewContext() / MainQueueMessageActionsCoreDataStack and prove the suite under -com.apple.CoreData.ConcurrencyDebug 1.

**Evidence.**
- `esc-chatmail/Services/PendingActions/MessageActions.swift:20` @MainActor final class MessageActions
- `esc-chatmail/Services/PendingActions/MessageActions.swift:418` archive(message:) removeFromLabels on viewContext
- `esc-chatmail/Services/PendingActions/MessageActions.swift:448` full conversation.messages fault
- `esc-chatmail/Services/PendingActions/MessageActions.swift:805` removeFromLabels + localModifiedAt per message
- `esc-chatmail/Services/PendingActions/MessageActions.swift:838` spam loop with addToLabels
- `esc-chatmail/Services/PendingActions/MessageActions.swift:316` read-state precedent on newBackgroundContext under the serializer

**Caveats.** Merges three cross-theme items (actions per-message faults, actions INBOX inverse fault, writepath main-thread label mutations). The INBOX fault magnitude differs about 7x between measurements (191 ms versus 28-36 ms at 120k).

#### Single-message archive recomputes the conversation rollup by fetching every remaining INBOX message as full objects on main

`single-archive-rollup-materializes-inbox` · ios · effort S

**Problem.** After every tap, archive(message:) calls updateConversationInboxStatus on the viewContext. That runs fetchInboxMessages, an unlimited full-object fetch, only to derive hasInbox, inboxUnreadCount (filtered in memory) and latestInboxDate, then saves a second time. The nonisolated fetchInboxMessagesForRollup has the same shape off main, and full rows include inline bodyText. After archiveConversation the helper returns about zero rows, so only the single-message path is affected.

**When it bites.** At S2/S3, in newsletter or notification l| conversations that stay in the inbox with thousands of INBOX rows. A 20k-message list materialized 17,585 rows in 96 ms with +165 MB (measured), estimated 100-300 ms per tap on device.

**What the user sees.** Archiving messages one after another in a big newsletter chat stutters on each tap.

**Fix.** Replace the materializing rollup with three queries: a count of (conversation == %@ AND ANY labels.id == INBOX) for hasInbox, the existing countUnreadInboxMessages for inboxUnreadCount, and a fetchLimit-1 request sorted by internalDate desc with propertiesToFetch [internalDate] for latestInboxDate. Apply the same change to fetchInboxMessagesForRollup. Run it on the background context inside rollupMutationSerializer, together with the mutation.

**Review correction (supersedes the fix above where they conflict).** Keep today's order inside one serializer block: save the mutation, then run the count, unread-count and limit-1 queries, then save the rollup. Running the limit-1 query alongside the unsaved mutation can return zero rows when the just-archived row was the newest INBOX row, which yields `hasInbox = true` with `latestInboxDate = nil`. The alternative is to exclude the mutated objectIDs with `NOT (SELF IN %@)`.

**Keep intact.** Rollup recompute and save happen inside one ConversationRollupMutationSerializer block. A failed read must not be treated as empty (keep the optional-return failure path).

**Tests.** MessageActionsTests: archiving one of several INBOX messages keeps hasInbox true with the correct unread count and latestInboxDate; archiving the last one clears all three. Revert-check naming the count/limit-1 helper.

**Evidence.**
- `esc-chatmail/Services/PendingActions/MessageActions.swift:423` archive(message:) -> updateConversationInboxStatus
- `esc-chatmail/Services/PendingActions/MessageActions.swift:724` updateConversationInboxStatus on viewContext
- `esc-chatmail/Services/PendingActions/MessageActions.swift:745` fetchInboxMessagesForRollup full-object fetch
- `esc-chatmail/Services/PendingActions/MessageActions.swift:762` countUnreadInboxMessages count-query precedent

**Caveats.** The cost is the auditor's estimate plus the storage theme's 96 ms / +165 MB measurement on the same fetch shape.

#### Opening any chat runs a main-thread unread-INBOX snapshot that SQLite drives from the store-wide byIsUnreadIndex, costing O(mailbox unread)

`chat-open-unread-snapshot` · ios · effort M

**Problem.** On first appear, markConversationAsReadIfNeeded calls snapshotUnreadInboxMessageObjectIDs(conversationID:) synchronously on the main viewContext, with `conversation.id == %@ AND isUnread == YES AND ANY labels.id == INBOX` and no fetchLimit. On the real model SQLite plans this as SEARCH on Z_Message_byIsUnreadIndex, with or without stats, so it probes every unread row in the mailbox even for a chat with 0 unread. Without stats the objectID form (conversation == %@, which the private sibling helper and countUnreadInboxMessages use) also picks byIsUnreadIndex. The resulting IDs then go to performMarkMessagesAsReadBatch, which resolves them one existingObject at a time and fires each row's labels fault.

**When it bites.** On every chat open, growing with unread mail across the whole mailbox. Measured warm on an M5 Pro: 39-41 ms at S2 (about 26k unread) and 140-160 ms at S3 (about 86k unread). The first cold touch takes 2.6-3.3 s at S3, and an iPhone is 2-3x slower. Opening a list with K = 5k unread adds about 10k single-row round trips off main before the badge clears.

**What the user sees.** Opening a chat hitches more as unread mail piles up, worst on the first open after launch. A large unread newsletter list can take a second or more to clear its badge.

**Fix.** Switch the public overload to the objectID predicate (ChatViewModel already holds conversation.objectID), run the fetch on a background context, and return objectIDs to the main actor. Keep includesPendingChanges = false and the snapshot-before-mark semantics. Without stats the planner can still pick byIsUnreadIndex, so in the ESCChatmail 7 version either drop byIsUnreadIndex or add a compound (conversation, isUnread) fetchIndex, with a versionHashModifier on Message. Dropping is safe: grep finds no caller of MessagePredicates.unread and no global unread count exists, so the snapshot is the index's only real user. Until v7 ships, the snapshot can fetch the conversation's rows by conversation == %@ through byConversationAndDateIndex and filter isUnread/INBOX in memory. In performMarkMessagesAsReadBatch, replace per-ID existingObject with chunked `SELF IN %@` fetches that prefetch labels, keeping the re-checks and the single serializer block.

**Keep intact.** Versioned xcdatamodel only, with a versionHashModifier, because index-only edits never migrate. Never drop byIsUnreadIndex before the objectID conversion lands, or the UUID form becomes a full SCAN t0. Keep the lease contract (makeAccountWorkRequest -> acquireAccountWorkLease -> isActiveRun -> endRun). Managed objects never cross contexts.

**Tests.** MessageActionsTests, using a main-queue context per CLAUDE.md: the objectID snapshot returns exactly this conversation's unread INBOX IDs and excludes another conversation's unread rows and any later arrival; a batch spanning more than one chunk marks every row and recomputes the rollup once. An SQLite plan test (scale harness) asserts the snapshot plan avoids byIsUnreadIndex, with a Revert-check naming the objectID predicate.

**Evidence.**
- `esc-chatmail/Services/PendingActions/MessageActions.swift:156` conversation.id == %@ AND isUnread == YES AND ANY labels.id == %@
- `esc-chatmail/Services/PendingActions/MessageActions.swift:164` synchronous viewContext fetch
- `esc-chatmail/ViewModels/ChatViewModel.swift:294` markConversationAsReadIfNeeded once per chat open
- `esc-chatmail/Services/PendingActions/MessageActions.swift:331` per-ID existingObject in the batch
- `esc-chatmail/Services/CoreData/NSManagedObjectContext+Fetch.swift:252` MessagePredicates.unread (no callers)
- `esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld/ESCChatmail 6.xcdatamodel/contents:160` byIsUnreadIndex

**Caveats.** Merges the actions and maintenance snapshot items. Plan measurements disagree: a Python sqlite run with ANALYZE seeked byConversationAndDateIndex in 0.0 ms for the pk form, while real-model Core Data runs without stats kept byIsUnreadIndex.

#### Chat transcript paging and counts filter on conversation.id (unindexed UUID join) with OFFSET; without sqlite_stat1 SQLite walks all of ZMESSAGE

`chat-transcript-uuid-join-offset-paging` · ios · effort M

**Problem.** MessagePredicates.visibleInChat(conversationId:) compiles to `JOIN ZCONVERSATION t1 ... WHERE t1.ZID = ?` plus a correlated label SUBQUERY. ZCONVERSATION.ZID has no index. On the real v6 schema without sqlite_stat1, the page plans as SCAN t0 USING INDEX byInternalDateIndex and the count as SCAN t0, so cost is O(mailbox). With stats it becomes SCAN ZCONVERSATION plus a TEMP B-TREE, which is O(conversations). Every loadMessagePage call (the 0..<0 metadata probe, the initial page, each preload, each slide, post-sync validation) also runs an OFFSET fetch plus an unconditional COUNT, so in a long chat every page costs O(N_conv). The object form (`conversation == %@`) always seeks byConversationAndDateIndex and already exists.

**When it bites.** Without stats (fresh store, store reset plus re-list, or BG-starved devices), measured on a Mac: at S2 the count takes 135-300 ms and the page 150-257 ms; at S3 the count takes 755-1328 ms and the page about 990 ms, so roughly 4-6 s per chat open on iPhone. With stats it is 1-60 ms. The join adds 0.7-0.9 ms per statement even in a 12-message chat, and in a 20k chat OFFSET makes the tail page 14-18 ms.

**What the user sees.** On a large mailbox, especially soon after install or after signing out and back in, a chat takes seconds to show its transcript. Older pages arrive late while scrolling back.

**Fix.** No schema change is needed for the main fix. Use visibleInChat(conversation:) with the cached conversation objectID, re-resolved per context, in loadMessagePage, loadPendingMessagePage, rowForGrouping and ChatPreviewRepair.retryScope. Replace OFFSET with keyset paging from the window boundary row (internalDate, id). Skip the COUNT on edge preloads and keep the total up to date from classified inserts and deletes, re-counting only in the metadata probe and post-sync validation. Also run one `PRAGMA optimize` or ANALYZE inside StoreMaintenanceCoordinator's exclusive run, off main, once initial sync or a re-list reaches its terminal cursor. A Conversation.id fetchIndex is optional and belongs in the ESCChatmail 7 version with a versionHashModifier (CREATE INDEX measured at 0.11 s at S3).

**Review correction (supersedes the fix above where they conflict).** Use the objectID predicate only for permanent IDs. `currentConversationObjectID()` deliberately does not cache temporary IDs, and a background page loader cannot resolve a temporary viewContext ID, so a newly composed chat would page nothing. Fall back to the UUID form, or `obtainPermanentIDs` after save. Keyset paging replaces the absolute-index model that `rowForGrouping(atAbsoluteIndex:)`, `totalMessageCount` and the window ranges are built on, so treat it as a separate step larger than M.

**Keep intact.** Managed objects never cross contexts: pass the objectID. Versioned xcdatamodel only, with a versionHashModifier, and update CLAUDE.md's 19-fetchIndex count. No hand-written SQL against Z-tables; ANALYZE through SQLiteDatabase is the sanctioned exception. Leave ChatTranscriptRealizationPolicy row realization untouched.

**Tests.** MessagePredicatesSQLiteTests: the transcript predicate uses the object form; page contents and order are identical for id-join versus object and for OFFSET versus keyset, including equal-internalDate ties. Scale-harness EXPLAIN test: no `SCAN t0` over ZMESSAGE, with a Revert-check naming visibleInChat(conversation:). VirtualScrollState paging and grouping parity tests.

**Evidence.**
- `esc-chatmail/Services/CoreData/NSManagedObjectContext+Fetch.swift:236` visibleInChat(conversationId:) uses conversation.id
- `esc-chatmail/Services/CoreData/NSManagedObjectContext+Fetch.swift:225` visibleInChat(conversation:) object form exists
- `esc-chatmail/ViewModels/VirtualScrollState+RowCache.swift:190-215` page OFFSET + COUNT per call
- `esc-chatmail/ViewModels/VirtualScrollState+ChangeObservation.swift:437` cachedConversationObjectID available
- `esc-chatmail/Services/ConversationList/ChatPreviewRepair.swift:381` retryScope uses conversation.id
- `esc-chatmail/Services/DatabaseMaintenance/DatabaseMaintenanceService.swift:53` daily BG ANALYZE is the only stats source

**Caveats.** Merges the maintenance UUID-join item with the UI page-loader item. The plan dispute is settled by stats state: the Python benchmark with ANALYZE showed O(conversations), while the real schema without stats showed a full ZMESSAGE scan.

#### Each sync insert into an open, latest-following chat re-counts the conversation and runs an OFFSET scan over it on the main thread

`chat-reconcile-main-count-offset` · ios · effort L

**Problem.** handleViewContextChange marks any visible insert, delete or visibility-flipping label change in the open conversation as a dataset change. The in-place tail append accepts only the user's own optimistic rows. Every other change, including incoming mail and the user's send echo, schedules reconcileWindowAfterDatasetMutation, which calls loadLatestWindow(forceViewContext: true). That forces loadPendingMessagePage on the main-queue viewContext: two COUNTs, one OFFSET fetch of up to 300 rows, and a re-map of up to 300 rows.

**When it bites.** Scales with the size of the open conversation: under 15 ms at 2k messages. A 10k-20k chat at S2/S3 takes about 34 ms of SQL on a Mac (synthetic), an estimated 70-150 ms on main on iPhone, for every arriving message and send echo. Queued reconciles supersede each other, so a burst costs about one.

**What the user sees.** While a long chat or newsletter list is open, each arriving message or send echo makes the transcript stutter.

**Fix.** Run the COUNT and the ID page on the background pageLoader context, and use the viewContext only to fold in its own unsaved insertedObjects. Extend the in-place tail append to sync inserts that sort strictly after the window's last row (visibleInsertedMessagesSortStrictlyAfterWindow already computes this), adjusting totalMessageCount by the delta instead of re-counting. Use keyset paging and the object predicate (chat-transcript-uuid-join-offset-paging). Keep validateWindowAfterSync as the healing path.

**Keep intact.** Managed objects never cross contexts. The echo is matched by the deterministic Message-ID, and sync owns replacing the optimistic row, so never rename or delete it. The echo swap keeps the row's ForEach identity, so markRowRealized/markRowUnrealized keep working.

**Tests.** VirtualScrollState reconciliation/tail-append suites: a sync insert strictly after the tail appends in place with no COUNT on the viewContext (counting pageLoader stub); an out-of-order insert still reconciles. SQLite-mode keyset page tests. Revert-check comments.

**Evidence.**
- `esc-chatmail/ViewModels/VirtualScrollState+ChangeObservation.swift:61` visible changes set orderedDatasetDidChange
- `esc-chatmail/ViewModels/VirtualScrollState+Reconciliation.swift:15` loadLatestWindow(forceViewContext: true)
- `esc-chatmail/ViewModels/VirtualScrollState+WindowLoading.swift:572` routes to loadPendingMessagePage on viewContext
- `esc-chatmail/ViewModels/VirtualScrollState+RowCache.swift:252` OFFSET/LIMIT + includesPendingChanges count
- `esc-chatmail/ViewModels/VirtualScrollState+TailAppend.swift:13` doc notes the full path re-counted on main

**Caveats.** Device timings are scaled from a macOS synthetic SQLite benchmark.

#### The sender-grouping lookahead runs a main-thread fetchOffset=index query from the view body after every historical window change

`chat-grouping-lookahead-offset` · ios · effort M

**Problem.** ChatMessagesView.body asks for the row just past the window. When endIndex < total, that reaches VirtualScrollState.rowForGrouping, a synchronous viewContext fetch on the main actor with fetchOffset = index, fetchLimit 1, the visibleInChat UUID predicate and three prefetch keypaths, which costs O(index). setMessageWindow clears the memo on every publication, so once the reader is more than 300 rows above the tail, every 50-row preloadPrevious triggers one such query inside body evaluation.

**When it bites.** Negligible below about 1k messages. A 20k chat at S2/S3 took 8.6-9.1 ms at OFFSET 10000 with stats (Mac), an estimated 20-40 ms on device. Without stats, measured on the real schema: 234 ms at S2 and about 905 ms at S3 per uncached index. That is one hitch per page load while scrolling back.

**What the user sees.** Scrolling back through a long chat's history hitches on the frame where older rows are prepended.

**Fix.** Carry the lookahead row in MessageWindow. Have the background page load fetch endIndex+1, or run a keyset fetchLimit-1 query with the object predicate, and publish the resolved row with the window so body evaluation never issues SQL. At minimum, move the fetch out of body into the window-load task. Keep the guard that latest windows never fetch.

**Keep intact.** Managed objects never cross contexts: carry the objectID or a ChatMessageRowModel snapshot. View decisions stay in pure Policy namespaces, and body stays declarative.

**Tests.** VirtualScrollState RowCache/window suites: after a back-trimmed preloadPrevious, the grouping neighbour is available with zero viewContext fetches (counting context), and grouping output is unchanged. Revert-check naming rowForGrouping's fetch.

**Evidence.**
- `esc-chatmail/ViewModels/VirtualScrollState+RowCache.swift:110` fetchOffset = index; fetchLimit = 1
- `esc-chatmail/ViewModels/VirtualScrollState+RowCache.swift:9` memo cleared in setMessageWindow
- `esc-chatmail/Views/Chat/ChatMessagesView.swift:993` messageRow(atAbsoluteIndex: end + 1)
- `esc-chatmail/Views/Chat/ChatMessagesView.swift:1007` rowForGrouping from the row body
- `esc-chatmail/ViewModels/VirtualScrollState+WindowLoading.swift:782` backTrimmed(to: maxWindowSize)

**Caveats.** The no-stats figures come from the maintenance theme and the with-stats figures from the UI theme. The object predicate removes the join cost, but OFFSET remains until keyset paging lands.

#### Every conversation-list page, backfill and pop-back reloads and re-snapshots the whole growing window on the main thread

`conversation-list-window-full-refetch` · ios · effort M

**Problem.** loadMoreIfNeeded adds 50 to loadedConversationLimit and reloads from offset 0 on the main-queue viewContext, prefetching participants and persons. listStore.replaceAll then rebuilds a ConversationSnapshot for every row, which walks participants, normalizes emails and sorts a fingerprint. The limit resets only on a filter or search change, so the window never shrinks, and the same full L-row reload runs on backfill after any archive or delete and on every pop-back from a chat. The .contacts/.other and search paths repeat it with a 5x candidate batch.

**When it bites.** Scales with how deep the user has scrolled. At about 50-80 µs per row, a 300-row window costs 15-25 ms per page and a 3,000-row window about 150 ms per page, reachable at S2/S3. A full scroll of 12k rows at S2 is about 238 reloads and 1.4M snapshot builds; after that, each archive swipe or pop-back repeats a 100-400 ms reload.

**What the user sees.** The chat list gets choppier the further the user scrolls, and archiving deep in the list or coming back from a chat stutters.

**Fix.** Page by keyset: fetch only pageSize rows after the current tail, using a predicate that mirrors ConversationListItem.SortKey (pinned, lastMessageDate, id), and append their snapshots. Backfill after a removal fetches only the missing rows past the tail. On pop-back, reuse the window and apply only what changed while hidden. Optionally cap the retained window at about 500 rows with back-trimming, and reset the limit when the user returns to the top. Keep publishVisibleItems as the single publish funnel. Do not add an FRC.

**Keep intact.** Never add a live @FetchRequest/FRC to ConversationListView. ConversationListItem.SortKey stays the one canonical order. publishVisibleItems remains the funnel that keeps the selection a subset of visible rows. fetchWindow's pending/persisted merge must keep unsaved viewContext rows.

**Tests.** ConversationListViewModel / ConversationWindowProvider: paging appends exactly pageSize rows with no re-snapshot of existing rows (spy); keyset order matches a full fetch, including pinned rows and date ties; backfill after an archive deep in the list fetches only the deficit. Revert-check comments.

**Evidence.**
- `esc-chatmail/ViewModels/ConversationListViewModel.swift:375` limit += pageSize; reloadConversationWindowFromStore()
- `esc-chatmail/ViewModels/ConversationListViewModel.swift:393` fetchWindow(limit: loadedConversationLimit)
- `esc-chatmail/ViewModels/ConversationListViewModel.swift:406` replaceAll + publishVisibleItems
- `esc-chatmail/ViewModels/ConversationListViewModel.swift:413` backfill full reload
- `esc-chatmail/Services/ConversationList/ConversationSnapshot.swift:69` per-row fingerprint sort/join

**Caveats.** Verifier severities split. This stays degrades because pop-back and backfill repeat the cost at whatever depth the user reached.

#### The Contacts and Other filters scan every active conversation and its participant graph on the main-queue context, restarting from offset 0 on each reload

`contacts-other-filter-main-scan` · ios · effort M

**Problem.** .contacts and .other have no store predicate, so fetchFilteredWindow pages from offset 0 in batches of 500, prefetching participants and persons, and runs isConversationWithContact in Swift until it has `limit` matches or reaches the end of the store. When matches are sparse, one reload materializes every active conversation with its participants on the main thread. It reruns on a filter change, on each debounced search keystroke, after every CNContactStoreDidChange (through the contactEmailsCache didSet), on each page and on backfill.

**When it bites.** S1 is about 4k objects and 20-40 ms. S2 (8-12k active conversations) is 35-50k objects, about 0.3-0.6 s on main per scan. S3 is 80-120k objects, about 0.8-1.5 s per filter switch, keystroke or contact edit. Estimates; materializing objects dominates, not SQL.

**What the user sees.** Choosing Contacts or Other, typing in search under those filters, or an iCloud contacts sync freezes the list for up to a second or more.

**Fix.** Push membership into SQL: `ANY participants.person.email IN %@` for .contacts, and `SUBQUERY(participants, $p, $p.person.email IN %@).@count == 0` for .other, with the normalized contact set as a parameter (chunked if large). Person.byEmailIndex serves it, and fetchLimit then works. Keep the in-memory re-check as a backstop. Also run any remaining scan on a background context that returns objectIDs, and resume from a keyset cursor instead of offset 0.

**Keep intact.** Managed objects never cross contexts. No FRC. SortKey stays canonical. Tests inject contactEmailLoader/accessRequester and never touch the real Contacts store.

**Tests.** ConversationFilterService / ConversationWindowProvider on .sqlite: the SQL predicate returns the same set as isConversationWithContact for mixed-case and legacy emails and for .other with 0, 1 or many contact participants; a sparse filter reaches `limit` without scanning the store (fetch-count spy). Revert-check comment.

**Evidence.**
- `esc-chatmail/Services/ConversationList/ConversationFilter.swift:42` needsInMemoryCandidateScan true
- `esc-chatmail/Services/ConversationList/ConversationWindowProvider.swift:96-98` candidate batches from offset 0
- `esc-chatmail/Services/ConversationList/ConversationFilterService.swift:101` per-participant normalize + contains
- `esc-chatmail/Services/ConversationList/ConversationFilterService.swift:22` contactEmailsCache didSet recompute

**Caveats.** An exact SQL IN match is correct only if every stored Person.email is normalized. findOrCreate normalizes on insert, but isConversationWithContact re-normalizes anyway, which hints at legacy rows.

#### Conversation-list search runs CONTAINS[cd] over every active row's uncapped snippet on the main thread for each debounced keystroke

`list-search-contains-uncapped-snippet` · ios · effort M

**Problem.** Search ANDs `(displayName CONTAINS[cd] %@) OR (snippet CONTAINS[cd] %@)` onto archivedAt == nil. No index can serve that, so SQLite folds case and diacritics over every active row, synchronously on the main-queue viewContext after each 150 ms debounce. For personal mail, Conversation.snippet is the latest message's whole de-quoted body (createCleanSnippet maxLength: Int.max), while the row shows only two lines.

**When it bites.** S1 scans about 2-5 MB per keystroke, which is fine. S2 scans 15-40 MB, an estimated 150-500 ms on main per keystroke; S3 scans 40-100 MB, 0.5-1.5 s. The cost is much lower if most active conversations are newsletters, which store only a subject.

**What the user sees.** Typing in the conversation search field stutters or freezes on large mailboxes.

**Fix.** Cap Conversation.snippet at write time to roughly 300-500 characters in every preview writer (MessagePersister+Helpers, CoreDataFactories, GmailSendService+OptimisticUpdates), or route them all through MessagePreviewText. Existing rows heal on the next rollup or through a launch truncation pass. Run the search candidate fetch on a background context that returns objectIDs. If search ever needs message content, use an FTS index outside Core Data or a normalized token attribute added in a new model version, never CONTAINS over bodyText.

**Review correction (supersedes the fix above where they conflict).** The writer list misses the authoritative rollup writer `ConversationRollupSnapshot.apply`, plus `ConversationRollupUpdater.swift:277`, `DataCleanupService+Migration.swift:290` and `GmailSendService+OptimisticUpdates.swift:1781`. Without them, every rollup writes the full snippet back, and unequal caps cause repeated dirty writes. Add one Conversation-only cap helper, not inside `MessagePreviewText.nonEmpty` (which `Message.snippet` also uses), and route every `Conversation.snippet` writer through it.

**Keep intact.** No FRC. No raw SQL against Z-tables. Do not change the preview selection rules; truncate only the stored result. Do not cap Message.cleanedSnippet, because bubble, full-view and context-menu text read it.

**Tests.** MessagePersister tests: the stored conversation snippet is capped and the two-line preview is unchanged. ConversationWindowProvider search tests, with a HONEST SCOPE comment for matches beyond the cap. Revert-check comments.

**Evidence.**
- `esc-chatmail/Services/ConversationList/ConversationWindowProvider.swift:150` CONTAINS[cd] predicate
- `esc-chatmail/Services/ConversationList/ConversationSearchService.swift:35` 150 ms debounce
- `esc-chatmail/Services/Sync/MessageProcessor.swift:889` createCleanSnippet(maxLength: Int.max)
- `esc-chatmail/Views/Chat/ConversationRowView.swift:195` lineLimit(2)

**Caveats.** Capping narrows what search matches to the stored prefix, which is a product-visible change. The real cost depends on the user's personal-versus-newsletter mix and was not measured on device.

#### Conversation row and chat header name loads run a DISTINCT sender scan over every message of the conversation on the main thread on every rollup-cache miss

`row-header-distinct-sender-scan` · ios · effort M

**Problem.** On a participant rollup-cache miss, ParticipantLoader runs context.perform on the main-queue viewContext and calls headerDisplayNamesByEmail. That is a DISTINCT (senderEmail, senderName) dictionary fetch over all of the conversation's messages, with no limit. byConversationAndDateIndex narrows the rows but does not cover the sender columns, so every wide, bodyText-inline row is read. Misses happen at launch, after the 300 s TTL, on LRU eviction (600 entries), and on every CNContactStoreDidChange (invalidateAll).

**When it bites.** Under 1 ms for typical conversations. At S2/S3 a 2k-20k-message 1:1 or transactional chat costs about 5-40 ms warm and an estimated 250-500 ms cold, per row, on main. Those chats usually sit at the top of the list.

**What the user sees.** Stalls on the first scroll after launch, after about 5 idle minutes, or after a contacts edit or sync, while names resolve.

**Fix.** Run fetchConversationParticipantSnapshot on a background context: re-resolve the objectID on newBackgroundContext and return only the value snapshot. Then bound it, either to the newest N messages (sorted internalDate desc with fetchLimit, deduped in memory) or, better, by persisting the best explicit header name per Person or (conversation, sender) at ingest, where isBetterDisplayName already runs. Consider a longer TTL for photo-less entries.

**Review correction (supersedes the fix above where they conflict).** The window shows unsaved conversations whose temporary objectIDs a background context cannot resolve. Run on the viewContext when `objectID.isTemporaryID`, otherwise on a background context with a bounded fetch.

**Keep intact.** Managed objects never cross contexts. Names keep going through PersonDisplayNameResolver.sanitizedExplicitDisplayName. Persisting at ingest stages into the caller's context, since only orchestrator save points save. A new attribute needs a new model version.

**Tests.** ParticipantLoader / ConversationParticipantExtractor: the snapshot fetch runs on a non-main context (injected factory) and yields identical names, including the contested case. If bounded to the newest N, the newest explicit name wins. Revert-check comments.

**Evidence.**
- `esc-chatmail/Views/Main/ConversationListView.swift:152` conversationContext: viewContext
- `esc-chatmail/Services/Contacts/ParticipantLoader.swift:339` context.perform { headerDisplayNamesByEmail }
- `esc-chatmail/Services/Conversation/ConversationParticipantExtractor.swift:97` DISTINCT dictionary fetch
- `esc-chatmail/Services/Contacts/ParticipantRollupDependencyTracker.swift:28` invalidateAll on contacts change

**Caveats.** Cold-cache timings are estimates. Bounding to the newest N slightly changes which historical name can win.

#### A merged Person update faults every conversation that Person ever joined, archived ones included, one at a time on the main thread

`person-change-conversation-fanout` · ios · effort S

**Problem.** Any Person in a merged update passes isRelevantConversationListChange. conversationsAffectedByPersonChanges then walks person.conversationParticipations and returns every conversation as a fault, with no archived filter, no window restriction and no prefetch. ConversationListStore.applyChanges reads archivedAt on each one (one single-row fault each), then builds a full snapshot that faults participants and persons one at a time, even for rows that trimVisibleItems will discard.

**When it bites.** k is 1-3 for a typical contact, but a prolific group participant reaches about 300-500 conversations at S2 and 1,000+ at S3. That is 2-3k individual faults, about 50-300 ms on main per update, chained across the dozens of Persons updated after a Contacts grant.

**What the user sees.** Brief list freezes while contact names resolve, especially just after granting Contacts access.

**Fix.** A Person change cannot change a row's sort key, so only rows already displayed can change. Replace the walk with one fetch: `self IN %@` (the window's objectIDs) AND `ANY participants.person IN %@`, prefetching participants and persons as handleSiblingContextSave does. Under Contacts/Other, a newly qualifying row outside the window goes through the existing backfill path.

**Keep intact.** No FRC; the objectsDidChange pipeline owns live updates. SortKey stays the canonical order. publishVisibleItems stays the single funnel.

**Tests.** ConversationListViewModel change-observation suite on .sqlite: a Person in 200 conversations (190 archived, 5 in the window) triggers a constant number of fetches and updates only the window rows. Revert-check naming conversationsAffectedByPersonChanges.

**Evidence.**
- `esc-chatmail/ViewModels/ConversationListViewModel+ChangeObservation.swift:125` any Person passes
- `esc-chatmail/ViewModels/ConversationListViewModel+ChangeObservation.swift:241` conversationParticipations walk
- `esc-chatmail/ViewModels/ConversationListViewModel.swift:432` archivedAt read per conversation
- `esc-chatmail/Services/Contacts/ContactPersistenceService.swift:32` Person writer saves per email

**Caveats.** Only Persons registered in the viewContext trigger it, which limits how often it fires but not k. Timings are estimates.


### Maintenance, migrations and SQLite

#### Six-hourly store-wide maintenance runs inside the incremental sync run before .syncCompleted, including a provably dead O(messages) duplicate scan

`six-hour-maintenance-inside-sync-run` · ios · effort M

**Problem.** IncrementalSyncOrchestrator awaits runIncrementalCleanup() after the commit and before posting .syncCompleted. When the 6 h cadence is due, it runs nine store-wide passes, each holding the cleanup-sensitive gate that optimistic-send creation also waits on. removeDuplicateMessages dictionary-fetches every Message.id even though Message.id has had a uniqueness constraint since v1, so it can never find anything, and runFullCleanup pays the same cost. removeDuplicateConversations scans keyHash values that embed a fresh UUID. mergeActiveConversationDuplicates and fixAndMergeIncorrectParticipantHashes load every active conversation with no batch size.

**When it bites.** Every 6 h, on the first sync past the mark. Measured shapes at S3 total about 0.55 s on an M5 Pro with a peak of about 170 MB (the id scan alone is 279 ms / +84 MB), about 1.5-2 s on device. S2 is roughly a third of that. The gate is held for the longest pass.

**What the user sees.** About every 6 hours, one refresh lands new mail a second or two later, a just-tapped reply bubble can lag behind the gate, and .syncCompleted observers fire late.

**Fix.** (1) Delete removeDuplicateMessages from maintenancePasses() and runFullCleanup; the uniqueness constraint makes it unreachable. (2) Detect keyHash and participantHash duplicates with a grouped count (propertiesToGroupBy plus a havingPredicate of count > 1) and load only those groups. (3) In fixAndMergeIncorrectParticipantHashes and mergeActiveConversationDuplicates, fetch only the compared attributes with fetchBatchSize of about 200 and periodic refresh. (4) Move the cadence-gated passes out of the sync run, into a separate StoreMaintenanceCoordinator exclusive .maintenance run started after .syncCompleted and skipped when busy. Do not use a non-exclusive lease, because these passes merge and delete conversations.

**Keep intact.** Every merge, dedup or cleanup pass excludes conversations named by in-flight OutboundSendMutationRecords and draft anchors (pendingSendConversationIDs). Keep per-pass holds and settleCleanupSensitiveHold. A lease holder never waits on beginRun/acquireRun, so the relocated maintenance must take the exclusive run itself.

**Tests.** DataCleanupService maintenance suites: maintenancePasses() no longer lists removeDuplicateMessages (Revert-check). Grouped-duplicate detection on a SQLite TestCoreDataStack still merges seeded duplicates and skips protected conversations. SyncRunCoordinatorTests: .syncCompleted posts before maintenance runs.

**Evidence.**
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:511` runIncrementalCleanup before .syncCompleted
- `esc-chatmail/Services/Sync/DataCleanupService.swift:15` interval 6 h; :189 maintenancePasses()
- `esc-chatmail/Services/Sync/DataCleanupService.swift:110` runFullCleanup also calls removeDuplicateMessages
- `esc-chatmail/Services/Sync/Cleanup/DataCleanupService+DuplicateRemoval.swift:12` every Message.id fetched
- `esc-chatmail/Services/Sync/Cleanup/DataCleanupService+Migration.swift:72` full active-conversation fetch, no batch

**Caveats.** The theme estimated 3-6 s at S3; the empirical harness measured 0.55 s on a Mac, so the device range uses that measurement. One refute verifier rated this hygiene.

#### The participant-set split migration walks every message under the cleanup gate inside the sync run, re-walks on every sync while blocked, and its rebuild phase faults every conversation's messages

`participant-split-migration-walk` · ios · effort L

**Problem.** runIncrementalCleanup wraps splitConversationsByParticipantSetIfNeeded in one cleanup-sensitive hold inside the sync run. Until hasDoneParticipantSetSplitV2 latches, Phase 1 fetches every Message (batch 500, with prefetch) in one perform with no cancellation check. Phase 2c fires conversation.messages for essentially every non-list conversation, with no refresh, so full rows stay registered. The flag stays clear while a protected draft or send anchor blocks a repair, and in that state every sync repeats the whole walk.

**When it bites.** One-shot on the first sync after upgrading a populated pre-V2 store, and on every sync while blocked. S2 takes an estimated 40-90 s with the gate and run held. At S3 it takes 2-5 min, and Phase 2c can register about 400k rows with bodyText, hundreds of MB, which risks jetsam.

**What the user sees.** After the upgrade, or while a draft or failed send anchors an affected chat, every sync finishes very late, reply bubbles wait on the gate, and large stores can crash.

**Fix.** (1) In Phase 2c, replace conversation.messages with a fetchLimit-1 `conversation == %@` request per candidate (participants prefetched), and refreshAllObjects every N candidates. (2) Persist the set of protected conversation IDs that blocked the latch, as ChatPreviewRepair.Checkpoint does; later syncs re-check only those and latch once the set is empty. (3) Run Phase 1 in ID-keyset slices, each in its own hold with a durable cursor and a cancellation check between slices.

**Review correction (supersedes the fix above where they conflict).** A plain fetchLimit-1 in Phase 2c can return a message with no participant rows, whose `strictParticipantSetIdentity` is nil, which silently skips the candidate. Walk newest-first in small batches with participants prefetched and stop at the first match, or add `participants.@count > 0` to the predicate.

**Keep intact.** Exclude OutboundSendMutationRecord and ChatReplyDraft conversations and DeferredRetryAnchors. A nil strictParticipantSetIdentity means do not re-home. List titles are never sender-derived. Rollups stay inside serializer blocks.

**Tests.** Split-migration suite, including testRetainedFailedSendDoesNotBlockUnrelatedMigrationWork: a blocked run persists only the blocking IDs and the next run does not re-walk; Phase 2c leaves hasFault(forRelationshipNamed: messages) true. Revert-check comments.

**Evidence.**
- `esc-chatmail/Services/Sync/DataCleanupService.swift:131` one hold around the migration
- `esc-chatmail/Services/Sync/Cleanup/DataCleanupService+Migration.swift:797` blocked leaves the flag clear
- `esc-chatmail/Services/Sync/Cleanup/DataCleanupService+Migration.swift:836` full Message walk
- `esc-chatmail/Services/Sync/Cleanup/DataCleanupService+Migration.swift:921` every source becomes a candidate
- `esc-chatmail/Services/Sync/Cleanup/DataCleanupService+Migration.swift:1286` conversation.messages fault per candidate

**Caveats.** A fresh install or reinstall latches the flag on a near-empty store and the flag survives sign-out, so exposure is limited to pre-V2 upgraders and the blocked-retry population. Estimates are unmeasured.

#### The weekly raw VACUUM rewrites the whole store through the WAL, leaves a DB-sized WAL, needs about 2x free space, and reclaims almost nothing

`weekly-full-vacuum-wal` · ios · effort M

**Problem.** performVacuum runs a bare VACUUM on a raw sqlite3_open connection with no busy timeout and no checkpoint, and discards rc/errmsg. In WAL mode the rebuilt DB is written into the -wal, so peak disk use is DB + temp + WAL. The WAL shrinks only at the next Core Data save; if the process dies first, the next launch pays WAL recovery on the synchronous main-actor store load. The store is already auto_vacuum=INCREMENTAL with a freelist of about 0.4%, so the rewrite frees almost nothing, and any failure reschedules a full week out.

**When it bites.** Measured on a Mac: 1.6-1.9 s at S2 with the WAL at 684 MB; 7.3 s at S3 with the WAL at 2.33 GB, reclaiming 27 MB. On device that is plausibly 15-40 s and 5-8 GB of transient free space. A launch after an un-checkpointed VACUUM measured +122 ms at S2, estimated 0.5-2 s at S3. A near-full phone fails with SQLITE_FULL every week.

**What the user sees.** Multi-GB storage spikes each week, a slower cold launch the next morning, and almost no space reclaimed.

**Fix.** Retire the unconditional VACUUM. If reclamation is wanted, gate it on freelist_count/page_count above 20-25% and free disk above 2.2x the DB size, and use `PRAGMA incremental_vacuum(N)` in bounded chunks. Set sqlite3_busy_timeout (about 5 s), finish with `PRAGMA wal_checkpoint(TRUNCATE)` before close, capture sqlite3_errcode/errmsg in DatabaseError, and reschedule after a short interval on failure. Replace the daily full ANALYZE with `PRAGMA optimize`. Never use NSSQLiteManualVacuumOption or NSSQLiteAnalyzeOption, which run on the main-actor launch path.

**Review correction (supersedes the fix above where they conflict).** To retire the task, keep a no-op handler registered for `com.esc.inboxchat.database.vacuum` for at least one release, cancel the pending request, and leave the Info.plist entry: devices already have a submitted request, and BGTaskScheduler can raise when it launches the app for an identifier with no handler. Drop the `incremental_vacuum` suggestion, because Core Data's post-save maintenance already runs it. Keep busy_timeout, the errmsg capture and `PRAGMA optimize`.

**Keep intact.** SQLiteDatabase stays a thin maintenance handle. Pragmas are fine, hand-written SQL against Z-tables stays forbidden. Maintenance stays inside StoreMaintenanceCoordinator's exclusive run.

**Tests.** DatabaseMaintenanceSchedulingTests: a failure reschedules after a short interval, and the freelist gate skips the work below threshold. A SQLite-mode test that maintenance leaves a truncated -wal, with a Revert-check naming wal_checkpoint.

**Evidence.**
- `esc-chatmail/Services/DatabaseMaintenance/DatabaseMaintenanceService+SQLite.swift:14` performSQLiteCommand(VACUUM)
- `esc-chatmail/Services/DatabaseMaintenance/SQLiteDatabase.swift:15` sqlite3_open, no busy_timeout/checkpoint
- `esc-chatmail/Services/DatabaseMaintenance/SQLiteDatabase.swift:35` rc/errmsg dropped
- `esc-chatmail/Services/Background/BackgroundTaskRegistry.swift:184` reschedule regardless of result

**Caveats.** One harness hit immediate SQLITE_BUSY when a write transaction was open at start; another saw VACUUM succeed alongside looping Core Data saves. Both are consistent: VACUUM fails only if a write is open the moment it starts.

#### BG maintenance (VACUUM, ANALYZE, cleanup) ignores expiration and holds an exclusive run that sign-out quiescence cannot cancel

`bg-maintenance-uncancellable` · ios · effort M

**Problem.** BackgroundTaskRegistry's expirationHandler only calls setTaskCompleted(false). It never cancels the handler Task, which later completes a second time, so Task.isCancelled checks never fire, and a VACUUM runs as one sqlite3_step with no sqlite3_interrupt. StoreMaintenanceCoordinator acquires the exclusive run with ActiveRun(task: nil), so beginQuiescence's cancel does nothing and sign-out or restore waits for the whole operation. Foreground sync is skipped ('already in progress') rather than parked, while pending-action flushes park behind it.

**When it bites.** Scales with store size. On device, VACUUM takes an estimated 15-60 s at S2 and 1-3 min at S3 (1.6-7.3 s measured on a Mac). A VACUUM suspended at expiry resumes when the app opens in the morning.

**What the user sees.** After an overnight maintenance window is cut short, the app opens with stale mail and sign-out hangs until maintenance finishes.

**Fix.** (1) Make expirationHandler cancel the handler Task and ensure setTaskCompleted runs exactly once. (2) Register the maintenance run together with its Task (a beginRunWithTask-style acquire) so beginQuiescence can cancel it, while still awaiting the drain. (3) Keep the db handle reachable and call sqlite3_interrupt from a withTaskCancellationHandler onCancel. (4) Pass cancellation into the cleanup passes and the HTML sweep. (5) Prefer PRAGMA optimize, and retire VACUUM per weekly-full-vacuum-wal.

**Keep intact.** The fixed teardown order (closeAdmission -> beginQuiescence -> cancelAndAwaitAll -> ...). Closing must drain: cancellation only shortens the drain. Gate waits are uncancellable, and no second transition may start inside one.

**Tests.** SyncRunCoordinatorTests: beginQuiescence cancels a task-registered maintenance run and awaits it. BackgroundTaskRegistry: expiration cancels the task and setTaskCompleted is called once. AuthSessionTests: sign-out during maintenance finishes promptly (Revert-check naming the task registration).

**Evidence.**
- `esc-chatmail/Services/DatabaseMaintenance/StoreMaintenanceCoordinator.swift:46` acquireRun(kind: .maintenance) with no task
- `esc-chatmail/Services/Sync/SyncRunCoordinator.swift:236` beginQuiescence cancels activeRun?.task
- `esc-chatmail/Services/Background/BackgroundTaskRegistry.swift:174` expiration only completes
- `esc-chatmail/Services/DatabaseMaintenance/SQLiteDatabase.swift:35` single sqlite3_step

**Caveats.** How long iOS lets a suspended VACUUM sit was not measured.

#### The daily HTML orphan sweep lists the flat Messages directory and unlinks orphans on the main actor while holding the global HTML lock

`html-orphan-sweep-main-thread` · ios · effort M

**Problem.** DatabaseMaintenanceService is @MainActor and cleanupOrphanedHTMLFiles is not nonisolated. After an off-main fetch of every Message.id into a Set, the synchronous HTMLContentHandler.cleanupOrphanedFiles runs on main. It does contentsOfDirectory over the whole flat directory, then an unlink and an invalidate per orphan, all inside HTMLContentAccountBoundary.perform, the NSRecursiveLock that every loadHTML, saveHTML and exists check also takes. The final saveIfNeeded is a performAndWait on main, and expiration never cancels any of it.

**When it bites.** About 120k files at S2, an estimated 0.5-3 s on main with the lock held. About 400k files at S3, 2-10 s, plus a 30-60 MB ID Set (the ID fetch measured 280 ms / +84 MB at S3). It matters only if the app is foregrounded while the sweep runs, and it adds jetsam risk in the background.

**What the user sees.** Usually invisible. If the user opens the app during the overnight sweep, the UI freezes for seconds and bubbles stay on Loading.

**Fix.** Make the sweep nonisolated and walk the directory off main with FileManager.enumerator, in chunks, inside HTMLContentHandler. Take the boundary lock per chunk or per deleteHTML(for:bodyStorageURI:expectedGeneration:) call with a generation captured up front, re-validating it and Task.isCancelled between chunks. Compare names per chunk with an `id IN %@` dictionary fetch instead of materializing all IDs. Replace the main-thread save with performSaveIfNeeded. Keep the rule that an unreadable ID set skips the sweep.

**Keep intact.** Body files are accessed only through HTMLContentHandler. Capture expectedGeneration and re-validate after every suspension. A failed read is never treated as empty. Stay inside the exclusive maintenance run.

**Tests.** HTMLContentAccountBoundaryTests: the chunked sweep refuses deletes after a generation change mid-sweep and stops on cancellation. A DatabaseMaintenance test that the sweep runs off main (Revert-check naming the nonisolated change).

**Evidence.**
- `esc-chatmail/Services/DatabaseMaintenance/DatabaseMaintenanceService.swift:7` @MainActor
- `esc-chatmail/Services/DatabaseMaintenance/DatabaseMaintenanceService+Cleanup.swift:100` main-isolated static sweep
- `esc-chatmail/Services/DatabaseMaintenance/DatabaseMaintenanceService+Cleanup.swift:124` cleanupOrphanedFiles on main
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:472` contentsOfDirectory inside accountBoundary.perform
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:15` NSRecursiveLock

**Caveats.** Merges the maintenance and storage items. The refute verifiers rated it hygiene because it is BG-only.

#### Each chatPreviewDerivationVersion or richContentVerdictEpoch bump re-reads every received HTML body, and the preview batches save on the main thread

`version-bump-full-mailbox-rederivation` · ios · effort M

**Problem.** ChatPreviewRepair.receivedHTMLRederivation scans every isFromMe == NO row, 25 per batch, loading HTML through the boundary lock under the cleanup-sensitive gate. Its completion key embeds chatPreviewDerivationVersion, so every bump re-arms a full-mailbox pass; the version was bumped four times between 2026-09-09 and 2026-09-17. RichContentVerdictBackfill walks every received row in the same way on an epoch bump. ConversationLaunchRepairCoordinator is @MainActor, so each changed preview batch does a performAndWait save on main, plus a UserDefaults write.

**When it bites.** Per bump, at an estimated 5-20 ms per row: S1 about 13k rows and 1-4 min of CPU; S2 about 105k rows and 3 GB read, 10-35 min; S3 about 360k rows, 1-2 h, spread across launches.

**What the user sees.** For days after an app update, battery drain and warmth, occasional main-thread hitches, and replies waiting behind a batch for the gate.

**Fix.** (1) Move the preview batch save off the main actor, as saveOffMainActor does, while keeping it inside the hold with no suspension between the save and the checkpoint write. (2) Treat bumps as expensive: document the cost next to both constants, and consider limiting a re-derivation to a recent window, leaving older rows to bubble-load re-derivation (older verdicts reading .unknown is legitimate). (3) Pause under Low Power Mode or serious thermal state. (4) Throttle checkpoint writes only if the checkpoint stays durable before the next suspension.

**Keep intact.** RichContentVerdictResolver is the only verdict definition, and .unknown is never a guess. Never skip an epoch bump to avoid the sweep. ChatPreviewRepair.backfilledPreview stays built from the loader's shared steps. The two passes stay independent. Body reads go through HTMLContentHandler.

**Tests.** ConversationLaunchRepairCoordinator / ChatPreviewRepair: the batch save is not on main, and the checkpoint is persisted after the save within the same hold (Revert-check). Window tests for RichContentVerdictBackfill if windowing is adopted.

**Evidence.**
- `esc-chatmail/Services/ConversationList/ChatPreviewRepair.swift:418` isFromMe == NO full scan
- `esc-chatmail/Services/ConversationList/ConversationLaunchRepairCoordinator.swift:128` key embeds the version
- `esc-chatmail/Services/ConversationList/ConversationLaunchRepairCoordinator.swift:347` saveIfNeeded on main
- `esc-chatmail/Services/ConversationList/RichContentVerdictBackfill.swift:63` full walk on epoch bump

**Caveats.** Per-row cost is unmeasured. Leaving older previews on the previous derivation is a product decision.


### Disk footprint and file lifecycle

#### On-disk HTML bodies have no retention, cap, compression or storage UI

`html-bodies-no-retention` · ios · effort XL

**Problem.** Every persisted message writes an uncompressed <id>.html into one flat Documents/Messages directory. Files are deleted only by per-message CacheCoordinator plans, which never run (deleted-message-file-reclamation), by the daily orphan sweep, and by teardown. cleanupOldFiles, calculateStorageSize, getDatabaseStatistics and performFullMaintenance have no callers, and no view shows storage. The footprint is therefore O(messages since install) with no ceiling, unlike the 100 MB image cache.

**When it bites.** S2 holds about 120k files (~3 GB); S3 about 400k files (10-20 GB estimated). On 64/128 GB devices that leads to low-storage warnings that name the app.

**What the user sees.** Settings > iPhone Storage shows the app growing by GBs a year, with no in-app way to see or reclaim it short of signing out.

**Fix.** Add a retention tier, not cleanupOldFiles as written (it keys on file creationDate, ignores Core Data and holds the lock for the whole walk). Bodies are recoverable (HTMLContentRecoveryService refetches on open), but on-disk HTML is an input to RichContentVerdictResolver and ChatPreviewRepair. So add a durable bodyEvicted marker in ESCChatmail 7, and teach the verdict, refresher, backfill and preview passes to treat 'evicted' as 'keep the stored verdict and preview', never as 'no HTML -> notRich'. Evict by internalDate age or LRU inside StoreMaintenanceCoordinator's exclusive run, under a captured generation, skipping rows named by in-flight send records and retained Not-sent rows. Expose calculateStorageSize in Settings. Consider compressing bodies behind HTMLContentHandler.

**Review correction (supersedes the fix above where they conflict).** Bodies are not transparently recoverable today. The bubble's recovery gate requires `missingBodyText` (`MessageBubbleLoader+CompatibilityContent.swift:195-205`), and almost every row has bodyText, so an evicted row would render its fallback text. The mismatched verdict would also schedule `RichContentVerdictRefresher` and overwrite the guarded stored verdict. The `bodyEvicted` marker must open the HTML-recovery gate and suppress the mismatch-triggered refresher for evicted rows. Add a loader test.

**Keep intact.** RichContentVerdictResolver stays the only definition and reads stored state only; .unknown is never a guess; bump richContentVerdictEpoch if classifier inputs change. The ChatPreviewRepair backfill leaves rows without local HTML blank. Versioned xcdatamodel only. HTMLContentHandler is the only body path. Capture the generation and re-validate after awaits. Never touch optimistic rows named by OutboundSendMutationRecord.

**Tests.** New HTMLBodyRetentionTests: eviction under a stale generation is rejected after reopen; an evicted row keeps its stored verdict across RichContentVerdictBackfill and the refresher (Revert-check: the evicted guard in classifierCandidate). Extend MessagePersisterRichContentVerdictTests and the ChatPreviewRepair tests.

**Evidence.**
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:226` atomic write per message
- `esc-chatmail/Services/Sync/MessagePersister.swift:144` saveHTML per message
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:446` cleanupOldFiles has no callers
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:428` calculateStorageSize has no callers

**Caveats.** Without the marker, eviction would flip card rows to text bubbles, because classifierCandidate falls through to bodyText when the file is missing. The S3 sizes are estimates.

#### Every received attachment is downloaded after each sync on any network and kept forever, with a second preview copy

`attachments-eager-permanent-download` · ios · effort L

**Problem.** Every synced attachment row starts as stateRaw queued. After every sync, schedulePendingAttachmentDownloads downloads every queued row serially, with no MIME, size, network-cost or user-setting filter. Images and PDFs also get a 1600 px preview, which for images already at or under 1600 px is a byte-identical second copy. Nothing evicts an original or a preview while its row exists.

**When it bites.** From S1 on: about 1 GB at S1, 5-10 GB of originals plus 1-3 GB of previews at S2, growing linearly after that (estimated). Every sync also downloads new attachments over cellular.

**What the user sees.** App storage balloons with images and PDFs the user never opened, and the app uses cellular data in the background.

**Fix.** (1) Add an auto-download policy to enqueueAllPendingAttachments: fetch only rows under a byte cap, or inline images a bubble needs, and only on non-expensive, non-constrained paths (an injected path monitor, like OutboundNetworkPathMonitoring). Leave the rest queued; views already download queued rows on appear, so they become lazy (there is no tap-to-download affordance). (2) Skip the Previews write when ImageProcessor returns the input unchanged, and resolve preview reads to the original. (3) Add LRU eviction of originals and previews unused for N days, run as a startDownloadOperation so teardown drains it: reset the row to queued, delete only through AttachmentCacheActor.deleteFile(at:expectedAccountGeneration:), and never evict non-inline local_ originals.

**Keep intact.** Drain before clear. Eviction is a registered download operation with generation-fenced deletes. Readers use readableLocalURLValue/readablePreviewURLValue. Reopen recreates directories. Keep the deliberate asymmetry that AttachmentCacheActor does not bump its generation on memory pressure.

**Tests.** AttachmentDownloaderTests: the policy skips large or expensive-network rows; an evicted row returns to queued and a later on-mount download restores it; eviction never touches local_ originals and is drained by cancelAndAwaitAllDownloads (stale generation rejected after reopen). Revert-check comments.

**Evidence.**
- `esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld/ESCChatmail 6.xcdatamodel/contents:20` stateRaw default queued
- `esc-chatmail/Services/Sync/SyncEngine.swift:301` schedulePendingAttachmentDownloads after sync
- `esc-chatmail/Services/Attachments/AttachmentDownloader.swift:796` serial getAttachment, no network-cost check
- `esc-chatmail/Services/Utilities/ImageProcessor.swift:32` scale >= 1 returns original bytes
- `esc-chatmail/Views/Components/Attachments/ImageAttachmentBubble.swift:83` on-appear download for queued rows

**Caveats.** The 200-400 KB mean attachment size is an estimate. Lazy download changes UX: a never-seen image shows loading on first view.

#### Uncapped inline bodyText and full-length preview columns make up most of ZMESSAGE and load on every Message fault

`inline-text-row-width` · ios · effort L

**Problem.** Message.bodyText stores the full plain text, or the full text extracted from the HTML, with no cap. cleanedSnippet is built with maxLength Int.max, and chatPreviewText, rawTo/Cc and references are stored verbatim, which duplicates the on-disk HTML inside SQLite. Core Data cannot fault String attributes lazily, and no managed-object Message fetch sets propertiesToFetch, so rollups, drainAndApply, archive rollups and the Phase 2c migration all materialize every body. ZMESSAGE is about 90% of the file, and columns after ZBODYTEXT cost overflow-page walks in scans (458 ms versus 6 ms at S3).

**When it bites.** The store measures 0.7-1.0 GB at S2 and 2.5-4 GB at S3 (2.46 GB measured, ZMESSAGE 2.16 GB). That size sets the cost of the WAL, VACUUM, recovery backups, iCloud backup and every full-object scan.

**What the user sees.** App data grows much faster than the message count suggests, on top of the HTML files. Rollups, archives and repairs spike memory.

**Fix.** Phase 1, no schema change: stop materializing full Message objects on non-bubble hot paths by using count or limit queries (single-archive-rollup-materializes-inbox, rollup-full-conversation-materialization) and narrow fetch shapes. First measure the real distribution with a diagnostic avg(length(ZBODYTEXT))/dbstat on a production-like store, not as app code. Phase 2, in ESCChatmail 7: consider storing plain-text bodies on disk behind HTMLContentHandler, or capping bodyText at what the bubble fallback needs, with a richContentVerdictEpoch bump. A 1:1 MessageBody entity alone does not shrink the file. Do not cap cleanedSnippet: bubble fallback, full view, context menu and reply indicators read it. Snippet capping for search is in list-search-contains-uncapped-snippet.

**Keep intact.** Versioned xcdatamodel only. No raw SQL in app code. bodyText and snippet are RichContentVerdictResolver inputs, so changing them requires an epoch bump. backfilledPreview stays built from MessageBubbleContentSource's shared steps. LegacyOutgoingBodyTextFallback relies on bodyText being richer than the stored HTML. SharedDocumentLinkExtractor.bubbleLinks inputs change together with storedRowLinks.

**Tests.** PerformanceRegressionTests (--performance) for rollup memory at a seeded S2 size. ConversationRollupUpdater tests confirming results after narrowing. If bodyText moves or is capped: MessagePersisterRichContentVerdictTests and RichContentVerdictIngestLoaderEquivalenceTests with an epoch-bump Revert-check.

**Evidence.**
- `esc-chatmail/Services/Sync/MessageProcessor.swift:121` resolvedPlainTextBody, no cap
- `esc-chatmail/Services/Sync/MessageProcessor.swift:889` createCleanSnippet(maxLength: Int.max)
- `esc-chatmail/Services/Sync/Persistence/MessagePersister+Creation.swift:113` bodyText written
- `esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld/ESCChatmail 6.xcdatamodel/contents:123` bodyText inline String

**Caveats.** All store sizes come from synthetic harness stores with assumed body lengths.

#### Multi-GB re-downloadable mail content sits in backed-up, non-purgeable directories with no isExcludedFromBackup

`no-backup-exclusion` · ios · effort S

**Problem.** Nothing sets isExcludedFromBackup. HTML lives in Documents/Messages and avatars in Documents/Avatars; attachments, previews and store backups live in Application Support, so iOS backs all of it up and never purges it. After a restore to a new device, the ThisDeviceOnly installation ID does not migrate but its UserDefaults copy does, so FreshInstallHandler wipes the restored content at first launch and the uploaded backup is thrown away.

**When it bites.** At S2, about 3 GB of HTML plus multi-GB of attachments, which alone exceeds the free 5 GB iCloud tier. At S3, 10-50 GB. Each daily backup re-uploads the day's new files (estimated).

**What the user sees.** 'iCloud Backup could not complete: not enough storage', or this app at the top of the iCloud backup list, and on a new phone the data is wiped anyway.

**Fix.** Set isExcludedFromBackup = true on Messages, Previews, Avatars, Backups and the re-downloadable part of Attachments everywhere these directories are created or recreated: HTMLContentHandler's creation and reopenAccountWork, AttachmentPaths.setupDirectories(), AvatarStorage init/deleteAllAvatars, and CoreDataBackupManager. The flag lives on the inode, so it must be re-applied after every teardown and recreate. Keep local_ (non-inline) compose originals, which cannot be re-downloaded, in a separate backed-up subfolder. Do not move canonical HTML to Caches: the verdict and preview passes read it as stored state. Avatars and thumbnails may move to Caches if their readers tolerate a missing file. Optionally exclude the SQLite store.

**Review correction (supersedes the fix above where they conflict).** Moving `local_` originals into a separate subfolder changes stored `localURL` values, which is a path migration through `readableLocalURLValue`, not effort S. Instead, exclude the Messages, Previews, Avatars and Backups directories, and inside Attachments set the flag per file at download time, leaving `local_` originals unflagged. Re-apply in every recreate path.

**Keep intact.** Reopen must recreate the deleted directories (setupDirectories, the Messages dir, the preview cache dir) and re-apply the exclusion there. Body access only through HTMLContentHandler. Canonical HTML must not become OS-purgeable.

**Tests.** AttachmentPathsTests / HTMLContentHandler tests: isExcludedFromBackup is true after setupDirectories() and after a teardown -> reopen cycle (Revert-check per recreate path). HTMLContentAccountBoundaryTests: the flag holds after reopenAccountWork.

**Evidence.**
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:117` Documents/Messages
- `esc-chatmail/Services/Attachments/AttachmentPaths.swift:25` Application Support Attachments/Previews
- `esc-chatmail/Services/Contacts/AvatarStorage.swift:15` Documents/Avatars
- `esc-chatmail/Services/CoreData/CoreDataBackupManager.swift:17` Backups
- `esc-chatmail/App/FreshInstallHandler.swift:128` keychain mismatch -> performCleanup

**Caveats.** Restores to the same device keep ThisDeviceOnly items, so backups are not always worthless. Sizes are estimates.

#### Deleting a message never deletes its HTML body or attachment files (post-save plan reads tombstones), and the fixed unlink loop must not run on the MainActor

`deleted-message-file-reclamation` · ios · effort M

**Problem.** CacheCoordinator keeps only NSManagedObjectID sets from didSave, hops to main, and later calls computeInvalidationPlan in a sourceContext.perform. At that point context.object(with:) on a committed deleted ID returns a tombstone: id, bodyStorageURI and localURL are nil and attachments is empty, with no exception (reproduced three times). So for every Gmail-side delete, TRASH/SPAM exclusion, dedup and draft cleanup, the plan is empty and costs one wasted single-row fetch per deleted object. A deleted Person reads a nil email, which clears the whole PersonCache. Files are reclaimed only by the daily BGProcessing orphan sweeps, which run only after a fully completed cleanup. Once the plan is repaired, performAsyncInvalidation's synchronous deleteHTML loop on the MainActor, under the global HTML lock, becomes a multi-second hang on bulk deletes.

**When it bites.** At S2/S3 for users who trash a lot on devices where BGProcessing rarely completes: about 250 MB of orphaned bodies per 10k deleted messages, plus attachments and previews. Once fixed, a 5,000-message purge would cost 0.5-2.5 s of main-thread unlinks if the loop stays on main (estimated).

**What the user sees.** App storage keeps growing after mail is trashed or deleted in Gmail. After a naive fix, the UI would freeze right after a large delete syncs.

**Fix.** Build the deleted-artifact half of the plan synchronously inside the existing compactMap stage on the posting queue, where the NSDeletedObjectsKey instances still carry values: message id and bodyStorageURI from deleted Messages, localURL/previewURL from the deleted Attachment instances themselves (message.attachments is already empty), and email from deleted Persons. Pass value structs down the pipeline and stop re-resolving deleted IDs. Treat a deleted Person as a single-entry eviction, not a full clear. Hand the HTML artifacts in one call to a nonisolated helper that unlinks under accountBoundary.perform with the captured generation, per file or in chunks of about 100 with cancellation checks, registered in invalidationTasks so closeAccountWorkAndAwait drains it. Before deleting an attachment file, confirm no surviving row references the same path. Keep the daily sweeps as the backstop.

**Review correction (supersedes the fix above where they conflict).** `deleteHTML(for:bodyStorageURI:)` unlinks `<id>.html` without checking for a live row. If the same Gmail ID is persisted again (un-spam or un-trash) before the deferred unlink runs, the new body is deleted. In each chunk, under the boundary lock, skip IDs that have a live Message row (an `id IN %@` dictionary fetch).

**Keep intact.** CacheCoordinator captures the generation, and now the values too, on the posting queue before .receive(on: .main). Drain before clear: the new task stays in invalidationTasks. Managed objects never cross contexts. Body files only through HTMLContentHandler. Attachment-scoped paths can be shared by sibling messages. RenderedMessageCache invalidation still flows through HTMLContentLoader.invalidateContent. Keep GmailSendServiceOptimisticFailureTests' exclusion of optimistic paths handed to the echo.

**Tests.** CacheCoordinatorInvalidationPlanTests in .sqlite mode: insert, save, delete, save, then assert the plan carries id, bodyStorageURI and attachment paths (Revert-check: post-time capture). An injected deleter records !Thread.isMainThread. Deleting a Person evicts only that entry. HTMLContentAccountBoundaryTests: a stale generation rejects deferred deletes after reopen.

**Evidence.**
- `esc-chatmail/Services/Caching/CacheCoordinator.swift:70` compactMap on posting queue captures only the generation
- `esc-chatmail/Services/Caching/CacheCoordinator.swift:154` later sourceContext.perform computes the plan
- `esc-chatmail/Services/Caching/CacheCoordinator.swift:190-202` object(with:) then id guard fails on tombstones
- `esc-chatmail/Services/Caching/CacheCoordinator.swift:357` synchronous deleteHTML loop on MainActor
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:300` deleteHTML's only production caller is CacheCoordinator
- `esc-chatmailTests/Caching/CacheCoordinatorInvalidationPlanTests.swift:55` test never sees post-save state

**Caveats.** Merges the storage reclamation item with the maintenance wasted-fetch / PersonCache item. Verifiers split between degrades and hygiene depending on how often the daily cleanup completes, which is unmeasured.

#### Sign-out, crash-resume and fresh-install cleanup unlink every body and attachment file on the auth-transition critical path

`signout-o-n-file-deletion` · ios · effort M

**Problem.** cleanupHTMLContent awaits deleteAllHTMLFromClosedAccount, which lists Messages and unlinks each file, aborting the whole loop on the first error. deleteAttachmentFilesFromDisk then removes Attachments, Previews and the legacy cache recursively. All of this runs inside performDurableLocalCleanup behind the FIFO auth gate, so it blocks the next sign-in and, after an interrupted sign-out, launch restore.

**When it bites.** About 150k unlinks at S2, 3-25 s; 400k+ at S3, 10-75 s (estimated at 20-150 µs each).

**What the user sees.** The sign-out spinner runs for tens of seconds and account switching is blocked. A relaunch after an interrupted sign-out sits on the launch screen.

**Fix.** Make the critical path O(1). Inside the closed boundary, after the drain, rename Messages, Attachments and Previews to same-volume tombstones (Messages.deleting-<uuid>), and let the existing reopen paths recreate empty live directories. A background sweeper, also run at launch until no tombstones remain, deletes them. Decide explicitly whether AccountScopedMailboxFileInspector and hasStoredHTMLFiles count tombstones. Stop aborting on the first failed unlink.

**Keep intact.** The fixed teardown order. Closing must drain. Reopen recreates the directories and re-applies the backup exclusion. The crash-resume pair takes no gate and gains no caller, and the sweeper must not become a second transition. prepareLocalStoreForAuthenticatedAccount stays correct.

**Tests.** AuthSessionTests: sign-out renames the tombstone and the next sign-in publishes before the sweeper finishes (Revert-check). HTMLContentAccountBoundaryTests: a stale generation is rejected while a tombstone exists. An AccountScopedMailboxFileInspector tombstone-policy test.

**Evidence.**
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:129` per-file removeItem loop
- `esc-chatmail/Services/Security/AuthSession.swift:374` deleteAllHTMLFromClosedAccount
- `esc-chatmail/Services/Security/AuthSession.swift:878` removeItem(attachmentsURL)
- `esc-chatmail/Services/Security/AuthSession.swift:1466` await cleanupHTMLContent()

**Caveats.** Per-unlink cost is estimated.

#### Store recovery backups are never pruned or restored, keep a full store's blocks, and survive sign-out

`recovery-backups-unpruned` · ios · effort S

> Raised to will-degrade by the review: after an account switch, the previous account's whole database stays on disk and in device backups, which is an account-isolation-at-rest problem.

**Problem.** Each reset or migration recovery clones the store into Application Support/Backups and then removes the live store, so on APFS the backup owns every block. cleanupOldBackups and listBackups are test-only, and nothing restores a backup. Neither teardown nor the isolation inspector touches Backups, so a previous account's mail metadata stays on disk and in device backups.

**When it bites.** Each event keeps 0.3-1 GB at S2 and 1-4 GB at S3, and events stack (estimated).

**What the user sees.** GBs that never come back after a reset; the previous account's database persists after switching accounts.

**Fix.** Either drop the backup, or export just the PendingAction rows to a small file and replay them. Otherwise call cleanupOldBackups(keepCount: 1) with an age cap after a successful load, delete Backups in performDurableLocalCleanup, add it to AccountScopedMailboxFileInspector, and exclude it from backup.

**Keep intact.** New destructive cleanup is wired into AuthSession's closures in the fixed order. A preserved send record never triggers a resend.

**Tests.** CoreDataBackupManagerTests / CoreDataRecoveryHandlerTests: backups are pruned after a reload. AuthSessionTests: sign-out removes Backups. Inspector test.

**Evidence.**
- `esc-chatmail/Services/CoreData/CoreDataBackupManager.swift:23` copyItem
- `esc-chatmail/Services/CoreData/CoreDataBackupManager.swift:88` cleanupOldBackups has no caller
- `esc-chatmail/Services/Security/AuthSession.swift:123` inspector omits Backups

**Caveats.** The data is at rest only and nothing in the app reads it.

#### A failed HTML write (ENOSPC) persists a body-less row with a known notRich verdict, the cursor advances, and nothing heals it

`enospc-bodyless-rows` · ios · effort M

**Problem.** HTMLContentHandler.saveHTML catches every write error and returns nil, exactly as it does for a closed account boundary. createNewMessage maps nil to no bodyStorageURI, inserts the row and does not throw, so the row is counted as persisted and the cursor may advance. stampRichContentVerdict then falls back to bodyText, which resolvedPlainTextBody always fills, and stores a known .notRich that RichContentVerdictBackfill never revisits. Bubble HTML recovery requires missingBodyText, so it never fires for typical rows.

**When it bites.** At any scale while the volume is near full, which multi-GB S2/S3 footprints make more likely. A week near full at about 100 messages a day leaves hundreds of rows permanently shown as plain-text bubbles.

**What the user sees.** While storage is low, newsletters render as stripped text bubbles, and they stay that way after space is freed.

**Fix.** Make saveHTML return a result (or throw) that distinguishes a closed boundary or generation mismatch from an I/O error. Treat out-of-space (NSFileWriteOutOfSpaceError, ENOSPC) as a run-level resource abort like isAccountScopedSyncAbort: no bucket, stop requests, rethrow so nothing commits. Do not record it as .failed, or the escape hatch abandons the IDs. Treat a boundary-closed nil as teardown or cancellation. For other I/O errors, if a body-less row must still be written, stamp .unknown so the backfill revisits it, and update the pinned 'Failed save' tests with a rationale. Ship together with sync-out-of-space-backoff.

**Review correction (supersedes the fix above where they conflict).** The "persist body-less and stamp `.unknown`" branch for other I/O errors does not heal: the backfill re-evaluates with no file and writes `.notRich` again, and bubble recovery stays closed. It also conflicts with the `MessageProcessor` body-materialization contract. Treat ENOSPC as a run-level resource abort, any other write failure as a blocking per-message `.failed` (cursor frozen, retried by re-scan), and a closed boundary as cancellation.

**Keep intact.** Resource aborts are run-level, like account-scoped aborts. Each ID goes to one disposition bucket unless the run aborts. Cancellation is thrown. .unknown is the answer when stored state could not be read. Only orchestrator save points save. Classify each new body error explicitly.

**Tests.** MessagePersisterDispositionTests: an injected ENOSPC saveHTML aborts the run with no disposition and no commit (Revert-check). IncrementalSyncCursorTests: the cursor stays frozen. Update the MessagePersisterRichContentVerdictTests 'Failed save' cases and RichContentVerdictIngestLoaderEquivalenceTests.

**Evidence.**
- `esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift:226` catch -> log, return nil
- `esc-chatmail/Services/Sync/MessagePersister.swift:144` no expectedGeneration
- `esc-chatmail/Services/Sync/Persistence/MessagePersister+Creation.swift:49` savedBodyStorageURI from saveHTML
- `esc-chatmail/Services/Chat/RichContentVerdictResolver.swift:123` falls back to bodyText
- `esc-chatmail/Services/Chat/MessageBubbleLoader+CompatibilityContent.swift:201` recovery needs missingBodyText
- `esc-chatmailTests/Sync/MessagePersisterRichContentVerdictTests.swift:286` failed save pinned to .notRich

**Caveats.** Persisting after a failed save is a deliberate, tested contract today; this changes it on purpose.

#### A persistent out-of-space save failure makes foreground sync retry every 60 s with no backoff and no storage message

`sync-out-of-space-backoff` · ios · effort M

**Problem.** Every sync save goes through saveAsync, which wraps any error as CoreDataError.saveFailed. The run rolls back correctly, but SyncEngine shows a generic 'Sync failed', and ForegroundSyncCoordinator's 60 s loop has no failure-aware backoff. Each run re-lists the frozen slice and re-fetches the uncommitted messages in full, and nothing checks free capacity.

**When it bites.** At any scale while the disk is full. A run aborts after about 50 fetches when intermediate saves are allowed. When only the final save fails, the whole backlog is re-fetched every minute (N=500 is about 2,500 quota units per minute). A full-disk initial sync restarts on every trigger.

**What the user sees.** 'Sync failed' with a generic message, battery and data drain, and no new mail, with nothing saying storage is full.

**Fix.** Use the shared out-of-space predicate (dead-disk-full-classification) to map these errors to a typed, run-level insufficient-storage outcome. Check volumeAvailableCapacityForImportantUsage at admission and refuse the run below about 200 MB. Back off exponentially (up to about 30 min) on that outcome and show a storage-full status. Leave the failure ledger untouched, and have BackgroundSyncManager's retry scheduling honour the same outcome.

**Keep intact.** Only orchestrator save points save. SyncFailureTracker success effects happen only via commit(_:) after the final save. Resource aborts are run-level. ModificationTracker commits or rolls back. Use FakeSyncClock in tests.

**Tests.** SyncRunCoordinatorTests / IncrementalSyncCursorTests: an injected out-of-space save leaves cursor and ledger frozen with the typed outcome (Revert-check). ForegroundSyncCoordinator with FakeSyncClock: follow-up runs are throttled. SyncFailureTrackerEscapeHatchTests: the run does not count as a strike.

**Evidence.**
- `esc-chatmail/Services/CoreData/CoreDataSaveOperations.swift:82` saveAsync throws saveFailed
- `esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift:571` rollback on error
- `esc-chatmail/Services/Sync/SyncEngine.swift:245` generic status
- `esc-chatmail/Services/Sync/ForegroundSyncCoordinator.swift:40` periodicInterval 60

**Caveats.** The auditor overstated the per-run cost; the abort happens after about 50 fetches when intermediate saves are allowed.


### Contacts and in-memory caches

#### Persisting any message invalidates the user's own address, so the next alias read re-queries Contacts, often with a full address-book enumeration

`self-alias-contacts-requery-per-persist` · ios · effort M

**Problem.** createNewMessage calls PersonCache.invalidateEntry for every participant, the user's own address included, which bumps that email's generation in the dependency tracker. AliasManager's cache fingerprints the account's own emails, so the first alias read after any persist misses and reruns ContactsSelfAliasProvider: predicate queries plus a full enumerateContacts when a Gmail address is on no card. ParticipantLoader awaits that read before every row load. refreshSendAsAliases also calls setAliases on both branches every run, and setAliases always recomputes.

**When it bites.** Present from S1, scaling with address-book size and sync activity: about 50-300 ms per recompute for 1-5k contacts (estimated). During a re-list, every uncached row load recomputes, and they serialize on the provider actor.

**What the user sees.** Row titles and avatars fill in slowly during and right after a sync, and Contacts I/O stays high.

**Fix.** Filter the current aliases out of participantEmails before invalidating, or key AliasManager validity on the global generation plus the Account alias list. Make setAliases a no-op when the aliases are unchanged and the fingerprint matches. Single-flight cacheAliases through a stored in-flight Task. Optionally reuse the normalized-email index from contacts-resolver-full-enumeration.

**Review correction (supersedes the fix above where they conflict).** Adopt only the AliasManager-validity option: global generation plus the Account alias list, with `setAliases` a no-op when nothing changed. Filtering the user's own aliases out of `invalidateEntry` would also stop PersonCache and rollup invalidation for the self Person, which note-to-self chats display.

**Keep intact.** Optimistic conversation hashing must keep using AliasManager.shared.getAliases(from: viewContext) with its Core Data fallback on a cold cache. An actual alias change must still trigger invalidateAll.

**Tests.** AliasManagerTests: persisting a message with self in To does not trigger a second provider call (counting fake); setAliases with an unchanged set does not re-query; concurrent getAliases callers share one query. Revert-check comments.

**Evidence.**
- `esc-chatmail/Services/Sync/Persistence/MessagePersister+Creation.swift:204-207` invalidateEntry for self too
- `esc-chatmail/Services/Sync/AliasManager.swift:34-38` fingerprint validity
- `esc-chatmail/Services/Sync/AliasManager.swift:71-75` setAliases always recomputes
- `esc-chatmail/Services/Sync/ContactsSelfAliasProvider.swift:103-111` full enumeration fallback
- `esc-chatmail/Services/Contacts/ParticipantLoader.swift:430` awaited per participant load

**Caveats.** Verifiers split between hygiene and degrades. It stays degrades because the read blocks visible row loads.

#### ContactsResolver enumerates the whole address book with thumbnails on every Gmail-address miss and every >10-email batch, never caches misses, and rewrites unchanged avatar files

`contacts-resolver-full-enumeration` · ios · effort M

**Problem.** lookup and prewarm cache only hits (NSCache 500). Gmail normalization strips dots and +tags, which defeats the predicate, so every Gmail miss falls back to an unpredicated enumerateContacts with thumbnail and formatter keys, run synchronously on the actor, and a true non-contact is scanned again on every call. performBatchLookup also enumerates everything whenever more than 10 uncached emails remain, and list paging sends up to 30 per page. Each hit then rewrites the avatar file atomically without checking whether it already exists.

**When it bites.** Scales with the number of Gmail correspondents who are not contacts (persons: 8k at S2, 20k at S3) and with scroll depth. Opening a chat can mean 30+ back-to-back scans at tens to hundreds of ms each, and a full list scroll about 240 scans at S2 and 600 at S3 (estimated).

**What the user sees.** Sender names and avatars appear seconds late, especially for Gmail senders not in Contacts, and scrolling uses extra battery and disk writes.

**Fix.** (1) Add a negative-result cache in ContactsResolver, cleared by invalidateAllCache(), CNContactStoreDidChange and closeAccountWorkAndClear. (2) Replace per-miss and batch scans with one lazily built normalized-email -> contact-identifier index that fetches only CNContactEmailAddressesKey, rebuilt on CNContactStoreDidChange, then fetch thumbnail and name by identifier after a hit. Keep it actor-owned and generation-fenced, and share it with ContactsSelfAliasProvider and compose autocomplete. (3) In saveAvatar, skip the write when the file exists with the same size or hash, and in updatePerson skip the save when nothing changed.

**Keep intact.** The new cache and index belong to the existing ContactsResolver boundary participant: cleared on close, fenced by its generation, and any in-flight build drained before reopen. Tests inject the store and loader and never use real Contacts.

**Tests.** ContactsResolverTests with a counting fake store: a repeated Gmail miss enumerates once; a store change clears the negative entry; a stale-generation index build is rejected after reopen. ProfilePhotoResolver: a second prefetch performs no enumeration and no file write. Revert-check comments.

**Evidence.**
- `esc-chatmail/Services/Contacts/ContactSearchService.swift:39` Gmail fallback to enumeration
- `esc-chatmail/Services/Contacts/ContactSearchService.swift:148` >10 emails -> full enumeration
- `esc-chatmail/Services/Contacts/ContactsResolver.swift:172` and :209 only hits cached
- `esc-chatmail/Services/TextProcessing/EmailNormalizer.swift:14` normalization defeats predicate
- `esc-chatmail/Services/Contacts/AvatarStorage.swift:42` unconditional atomic write

**Caveats.** Merges the memory miss-scan item with the storage prefetch/avatar-rewrite item. Cost depends on device address-book size, which is unknowable from code.

#### Compose autocomplete enumerates the whole address book with thumbnails on every debounced keystroke, with no cap and no cancellation

`compose-autocomplete-full-scan-per-keystroke` · ios · effort M

**Problem.** ContactsService.performContactSearch makes a name-predicate pass and then an unpredicated pass over every contact, both fetching thumbnails, and copies thumbnail Data for every match. The work runs in Task.detached, so searchTask.cancel() never reaches it and superseded scans overlap. Results are uncapped.

**When it bites.** Independent of mailbox size. With 1-2k contacts, each keystroke costs about 50-300 ms (estimated), and fast typing stacks several scans.

**What the user sees.** Recipient suggestions lag behind typing on large address books.

**Fix.** Drop thumbnail keys from both passes and load avatars by identifier for visible suggestions only. Cap results at about 20. Check cancellation inside the enumerate block and propagate it with withTaskCancellationHandler. Better, filter the shared in-memory index (contacts-resolver-full-enumeration).

**Keep intact.** Inject contactEmailLoader / accessRequester in tests.

**Tests.** ContactAutocompleteServiceTests: results are capped; a superseded query observes cancellation; no thumbnail key is requested. Revert-check comments.

**Evidence.**
- `esc-chatmail/Models/ContactsService.swift:187` unpredicated second pass
- `esc-chatmail/Models/ContactsService.swift:15` thumbnail key fetched
- `esc-chatmail/Models/ContactsService.swift:141` Task.detached
- `esc-chatmail/Services/Compose/ContactAutocompleteService.swift:34` cancel does not stop the scan

**Caveats.** Rendering is a LazyVStack, so the scan and the thumbnail copies dominate the cost.

#### ParsedEmailProvider keeps 256 full-HTML parse results with no byte cap, FIFO eviction and no memory-warning hook

`parsed-email-cache-no-byte-cap` · ios · effort M

**Problem.** ParsedEmailProvider is an actor holding a dictionary capped only by count (256). It has no byte budget, hits do not reorder (so eviction is FIFO), and it is not a MemoryWarningHandler. Each value retains canonicalHTML, plain text, summaries, and either reader render quality or preview images. A memory warning clears the other caches but not this one.

**When it bites.** Depends on the session, not the store: about 15-40 MB at typical sizes, and 80-130 MB for a newsletter-heavy S3 user with 300-500 KB bodies, which survives didReceiveMemoryWarning (estimated).

**What the user sees.** Higher resident memory during long sessions and more jetsam kills on 3-4 GB devices.

**Fix.** Add a byte budget based on the summed utf8 counts. Make eviction LRU with an O(1) ordered structure. Conform to MemoryWarningHandler and clear storage without bumping accountGeneration. Optionally stop storing canonicalHTML, which callers already hold.

**Keep intact.** closeAccountWorkAndClear still drains in-flight parses first. A memory-warning clear does not bump the account generation (the same asymmetry as AttachmentCacheActor). Do not grow this into a second bubble-text cache.

**Tests.** ParsedEmailProviderTests: byte-budget eviction; LRU touch on hit; a memory-warning clear keeps in-flight results storable. Revert-check comments.

**Evidence.**
- `esc-chatmail/Services/EmailDOM/ParsedEmail.swift:253` actor ParsedEmailProvider
- `esc-chatmail/Services/EmailDOM/ParsedEmail.swift:266` countLimit 256, no byte limit
- `esc-chatmail/Services/EmailDOM/ParsedEmail.swift:424` FIFO eviction

**Caveats.** The refute verifier rated this hygiene. Memory figures are estimates.


### Web PWA

#### Web rollup, inbox-indicator refresh and reply metadata deserialize every message of a conversation on every touch

`web-per-conversation-full-scans` · web · effort M

**Problem.** rollupConversation calls toArray() over the whole [conversationId+internalDate] range, bodyText included, and computes previews for almost every visible message, inside finalizeSync and in list-sync, send finalize and repairs. refreshInboxIndicators does another full read on INBOX removal. buildReplyMetadata reads the whole conversation before the optimistic insert, only to find the newest row. The web has no l| routing, so newsletters grow without bound.

**When it bites.** Tail conversations reach 1-5k messages at S2 and 5-15k at S3. A 5k conversation is about 25-30 MB deserialized and 0.5-2 s per touch (estimated).

**What the user sees.** In the largest chats, the reply bubble appears late, and the UI freezes briefly when mail lands in a big thread.

**Fix.** Derive unread and inbox counts from [conversationId+isUnread] plus the INBOX filter. Find the newest visible row with a reverse() cursor that stops at the first match, and get the sent/received flags from a new [conversationId+isFromMe] index (new Dexie version). Compute the preview only for the winner. In buildReplyMetadata, read reverse().first() and walk newest-first only while hints are missing.

**Keep intact.** The rollup stays the single archive-state authority. Outgoing messages never set inbox presence. Recompute and save in one transaction. Schema changes go through a new Dexie version.

**Tests.** A rollup vitest checking the indexed rollup equals the legacy full scan over randomized conversations (sent-only, archived, blank-preview). A replyMetadata newest-first test. Revert-check comments.

**Evidence.**
- `web/src/rollup/rollup.ts:229` full toArray
- `web/src/rollup/rollup.ts:114` preview per newer visible message
- `web/src/sync/persist.ts:584` refreshInboxIndicators full read
- `web/src/outbox/replyMetadata.ts:159` full conversation read
- `web/src/outbox/send.ts:321` awaited before optimistic insert

**Caveats.** The 'O(n) previews' framing is slightly overstated. Costs are estimates.

#### The web Unread filter and search cursor-walk every active conversation on each liveQuery invalidation, and sync invalidates once per message

`web-conversation-list-filter-walk` · web · effort M

**Problem.** queryConversationList applies unread and search predicates through Collection.filter over the [isArchived+pinned+lastMessageDate] range until it has limit+1 matches, which means walking the whole active set when matches are sparse. No index covers unread state. applyPersist commits one transaction per message and always puts the conversation row, so a sync of N messages triggers up to N re-walks.

**When it bites.** About 8-12k active rows at S2, 0.3-1 s per walk; 30k at S3, 1-3 s per walk, repeated almost continuously during sync with a filter active (estimated).

**What the user sees.** With the Unread filter on or a search typed, the list lags and the tab burns CPU during sync.

**Fix.** Add a 0|1 hasInboxUnread mirror and a [isArchived+pinned+hasInboxUnread+lastMessageDate] index in a new Dexie version, written in the same transaction as the rollup and the fast paths. Skip conversations.put when the row is unchanged. For search, batch applies per page or debounce the list liveQuery while syncing.

**Keep intact.** No second always-on whole-result live query (the web analogue of the no-FRC trap). The rollup owns inboxUnreadCount, and the mirror is written in the same transaction. Backfill the mirror in the upgrade.

**Tests.** live/queries vitest: the unread page comes from the index (count cursor steps); the mirror stays consistent through the fast paths, rollup and mark-read; an unchanged fast update does no put. Revert-check.

**Evidence.**
- `web/src/live/queries.ts:56` Collection.filter + limit
- `web/src/sync/persist.ts:823` per-message rw transaction
- `web/src/db/schema.ts:38` no unread index

**Caveats.** Per-walk costs are estimates.

#### Web incremental phase 2 fetches and parses the whole history backlog in memory before persisting any message

`web-incremental-fetch-unpaged` · web · effort M

**Problem.** runIncrementalSync passes every messagesAdded ID from up to 50 pages (up to about 5,000) to one fetchMessagesBounded call, which keeps every full GmailMessage. preparePersist then parses the whole batch before the first write, whereas initial sync and recovery fetch, prepare and apply per 500-ID page. A tab closed mid-run loses all the fetch work.

**When it bites.** After a week away: about 770 IDs at S2 (50-150 MB peak) and 1,500 at S3. Near the 5,000 cap, several hundred MB and minutes before the first row appears (estimated).

**What the user sees.** After a vacation, nothing new appears for minutes and then everything at once, and phones may reload mid-sync.

**Fix.** Chunk phase 2 like listSyncPages: slices of 100-200 IDs in chronological order, accumulating touchedConversationIds, with label ops after all slices and a single finalizeSync committing rollups, cursor and continuation. Pair it with the stored-ID filter from web-history-truncation-no-continuation.

**Keep intact.** Sequential, chronological persistence. Cursor and rollups commit only at finalize. Any slice failure freezes the cursor. Cancellation is never a verdict.

**Tests.** incremental.test.ts and the crash-matrix test: slice-1 rows persist before slice 2 is fetched; a slice-2 failure leaves the cursor unchanged; order is chronological across slices. Revert-check.

**Evidence.**
- `web/src/sync/incremental.ts:359` single fetchMessagesBounded
- `web/src/sync/incremental.ts:364` preparePersist over the whole set
- `web/src/sync/fetch.ts:122` every full message kept
- `web/src/sync/initial.ts:85` list-sync is per page

**Caveats.** Memory was corrected downward because inline attachments arrive by attachmentId.


## Hygiene

Slow-growing or cheap today. Pick these up when touching the surrounding code.


### iOS

- **The persistent store load and any lightweight migration run synchronously on the MainActor** (`esc-chatmail/App/AppStartupBootstrap.swift:17`). prepareProductionAppPersistence is @MainActor and is the first code to touch the lazy persistentContainer. Fix: Before shipping ESCChatmail 7, set shouldAddStoreAsynchronously = true (or load on a background queue) and keep waitForStoreToLoad as the real readiness gate. Audit the recovery ladder for the off-main completion (the retry Task, attemptMigrationRecovery, attemptStoreReset), and confirm nothing touches viewContext before the gate opens. Effort M.
- **Duplicate and dead indexes are maintained on every write, and an index-only model edit never reaches existing stores** (`esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld/ESCChatmail 6.xcdatamodel/contents:157`). Z_Message_UNIQUE_id, from the uniqueness constraint, is byte-identical to the declared byIdIndex, and the planner always picks the UNIQUE one; SyncCheckpoint.kind and AbandonedSyncMessage.gmailMessageId have the same pairing. Fix: Do not cut a model version for this alone. In ESCChatmail 7, drop byIdIndex, byGmThreadIdIndex and Conversation.byHiddenIndex, and optionally the duplicate SyncCheckpoint/AbandonedSyncMessage fetch indexes. Effort M.
- **removeStaleLabels fires each user label's messages to-many fault just to test emptiness** (`esc-chatmail/Services/Sync/Cleanup/DataCleanupService+EntityCleanup.swift:354`). Inside the 6 h cleanupOrphanedData pass, removeStaleLabels reads label.messages?.count for every non-system label. Fix: Use one Label fetch with a `messages.@count == 0` predicate (excluding system IDs), or a per-label count(for:) on `ANY labels == %@` with fetchLimit 1, inside the existing hold. Effort S.
- **Persistent history is recorded on every save with no consumer, but purged only by the daily BGProcessing cleanup, in one unbounded delete** (`esc-chatmail/Services/CoreData/CoreDataStack.swift:142`). NSPersistentHistoryTrackingKey is on and nothing reads history, but turning it off on an existing store logs a fault. Fix: Add an opportunistic foreground purge after .syncCompleted, at most once per 24 h, through StoreMaintenanceCoordinator.runWhenStoreIsIdle, skipped when busy. Shorten retention to about 1 day, since nothing consumes history; with 7 days, a purge shortly after a re-list deletes nothing. Effort S.
- **Not-sent and delivery-unknown send records are re-walked synchronously on the main actor at every launch and auth change** (`esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift:1227`). Ambiguous and not-sent OutboundSendMutationRecords live until the user acts or an echo arrives. Fix: Narrow the fetch predicate to records that still need conversion (inFlight and legacy nil), and skip terminal records before creating the private context. Never delete or auto-retry records. Effort S.
- **The one-shot V6 display-name refresh loads every message of every conversation into one context; a future key bump would spike memory at S2/S3** (`esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift:349`). refreshConversationNames runs updateDisplayNamesForAllConversations while hasRefreshedConversationNamesV6 is unset. Fix: Leave it alone unless the key must change; CLAUDE.md discourages bumps because repairListConversationTitles heals titles on every launch. Before any bump, add a running guard and a sync-idle wait, and chunk by conversation ID with dictionary sender fetches, a per-chunk save and reset, off main (the repairMissingConversationPreviews pattern). Effort M.
- **PerformanceRegressionTests run on an in-memory store with 220-360 conversations, so no test can see SQL plans, index use or fault costs** (`esc-chatmailTests/Performance/PerformanceRegressionTests.swift:26`). PerformanceRegressionTests builds an in-memory TestCoreDataStack and seeds 220-360 conversations and one 420-message thread. Fix: Add an opt-in SQLite-backed suite (TestCoreDataStack(storeKind: .sqlite)) seeded with bulk inserts to roughly S2 shape, resetting per batch. Assert structure rather than wall time: no `SCAN t0` over ZMESSAGE in the transcript and snapshot plans; hasFault(forRelationshipNamed: messages) still true on INBOX after persist, archive and delete; registered-object bounds per sync page. Effort M.
- **The post-sync attachment sweep fully scans the unindexed Attachment table and re-checks every local_inline_ row with a fault and a file stat** (`esc-chatmail/Services/Attachments/AttachmentDownloader.swift:552-583`). After every sync, enqueueAllPendingAttachments fetches `stateRaw == queued OR id BEGINSWITH local_inline_`. Fix: Do not narrow the local_inline_ disjunct to non-downloaded rows. Gate it behind a versioned one-shot flag, set after a sweep finds nothing to migrate, and split the queued branch into a plain equality query. Effort M.
- **The new-message fast path fires the Conversation.messages to-many fault on each unread INBOX arrival just to test for a sole message** (`esc-chatmail/Services/Sync/Persistence/MessagePersister+Helpers.swift:636`). applyFastConversationListUpdateForNewMessage computes isOnlyMessage from conversation.messages?.count, which fires a PK fetch of every message ID. Fix: Pass a 'created by this persist' flag from ConversationCreationSerializer, or use count(for:) with fetchLimit 2. Fold it in only when touching this path, and it disappears with the bounded-rollup refactor. Effort S.
- **A better display name for a Person refetches each of that person's conversations with every message prefetched** (`esc-chatmail/Services/Sync/Persistence/MessagePersister+Participants.swift:102`). When isBetterDisplayName accepts a better name, every conversation the person participates in goes to displayNameOnlyConversations. Fix: Get the IDs with one objectID fetch (`ANY participants.person == %@`), and have updateDisplayNameOnly read sender fields through a dictionary fetch instead of full rows. Effort M.
- **RenderedMessageCache keeps one invalidation-generation entry per distinct invalidated message ID until a global clear** (`esc-chatmail/Services/Caching/RenderedMessageCache.swift:825`). invalidate(messageId:) always bumps messageInvalidationGenerations[messageId], even for uncached messages. Fix: Compact by calling advanceGlobalInvalidationGeneration() when the map passes a threshold (about 4,096 entries), preferably when inFlight is empty so no in-flight work is wasted. This is safe because globalGeneration is part of every snapshot, so every outstanding producer and waiter is conservatively rejected. Effort S.
- **AttachmentCacheActor's attachment-to-identity index is never pruned on LRU eviction** (`esc-chatmail/Services/Caching/AttachmentCacheActor.swift:21`). registerCacheIdentity inserts before every image load, even when the load misses or fails. Fix: Bound the index with an LRU at about 2x the thumbnail cache size, or prune an entry once none of its identities remain cached, and register only after a successful store. Effort S.
- **Several small per-session maps only grow until a global reset** (`esc-chatmail/Services/Contacts/ParticipantRollupDependencyTracker.swift:72`). ParticipantRollupDependencyTracker.emailGenerations gets one entry per distinct invalidated email and is cleared only by invalidateAll. Fix: Optional. Collapse emailGenerations into a global bump past about 2,000 entries, and sweep expired noHTMLMisses on insert. Effort S.
- **GoogleDriveSharedFileMetadataProvider.cachedMetadata is never bounded or cleared** (`esc-chatmail/Services/Preview/GoogleDriveSharedFileMetadataProvider.swift:15`). cachedMetadata is a plain dictionary with a single writer and no eviction, memory-warning hook or boundary participation. Fix: Use an NSCache with a countLimit of about 512, or a bounded LRU. Effort S.
- **Each completed pending action re-fetches and JSON-decodes every live payload-bearing action, O(L^2) over a queue drain** (`esc-chatmail/Services/PendingActions/PendingActionProcessor.swift:371`). Each success calls clearLocalModifications, which fetches every live action matching `messageId IN completed OR payload != nil` and decodes each payload. Fix: Cache each live action's parsed target IDs per processing run, keyed by objectID, parsing on a miss. Effort S.
- **ModificationTracker copies its whole pending Set on every tracked insert (copy-on-write miss)** (`esc-chatmail/Services/Sync/ModificationTracker.swift:173-179`). `guard let state = transactions[id]` followed by `case .active(var modifications)` mutates a Set that the dictionary still references, so every insert copies it. Fix: Take the value out with removeValue(forKey:), mutate it, and reinsert it (or keep a separate dictionary mutated in place), and make the array overload a single formUnion. Effort S.
- **Gmail labels created after initial sync never get a local Label row, so their message joins are silently dropped** (`esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:135`). listLabels/saveLabels has one caller, InitialSyncOrchestrator. Fix: On a slow TTL inside the incremental run, call listLabels and stage saveLabels into the sync context before prefetchLabelIds. Effort M.
- **mergeDuplicatePersons faults the survivor's entire messageParticipations set and dirties every loser row in one perform** (`esc-chatmail/Services/Conversation/ConversationCreationSerializer.swift:87`). Person.email has no uniqueness constraint, and the serializer's sibling context creates duplicates by design. Fix: Build the survivor key set with a dictionary fetch, save and reset per group, and longer term pass pending Person objectIDs into the serializer. Effort M.
- **Avatar filenames collide on a 24-byte email prefix, and avatar files are never deleted or covered by teardown** (`esc-chatmail/Services/Contacts/AvatarStorage.swift:125`). safeFilename uses base64(email).prefix(32), which encodes only the first 24 bytes, so two addresses sharing that prefix share one file. Fix: Use a SHA-256 filename and store relative names, migrating by clearing avatarURLs. Wire deleteAllAvatars into teardown as a drained participant, add the directory to FreshInstallHandler and the inspector, and exclude it from backup or move it to Caches. Effort M.
- **The disk-full classifier is dead code, and the unused save-retry helper would turn SQLite errors into a silent rollback reported as success** (`esc-chatmail/Services/ErrorHandling/FileSystemErrorClassifier.swift:110`). FileSystemErrorClassifier.isDiskFullError and FileSystemError.diskFull have no callers, so nothing detects out-of-space. Fix: Delete save(context:retryCount:) or fix it. Replace the dead classifier with one public out-of-space predicate that walks NSUnderlyingErrorKey and covers 640, ENOSPC and SQLite 13, and use it in the ladder, the persister and the sync backoff. Effort S.
- **Re-fetching an already-stored message rewrites its HTML file and replaces every label join; history fetch and recovery never skip stored IDs** (`esc-chatmail/Services/Sync/Persistence/MessagePersister+Updates.swift:221`). MessageFetchPhase and recovery full-fetch every ID without an existence filter. Fix: Skip saveHTML when the source signature is unchanged, and diff label sets instead of clearing them. In the fetch phase and recovery, use one indexed `id IN` dictionary fetch and skip IDs that are already present (or refresh their metadata), but keep send echoes on the full fetch. Effort M.
- **Each created message spawns an unbounded detached avatar-prefetch task, and misses beyond the 500-entry cache are looked up twice and never negatively cached** (`esc-chatmail/Services/Sync/Persistence/MessagePersister+Creation.swift:211`). MessagePersister+Creation fires an uncounted, uncancelled Task.detached photo prefetch for every created message. Fix: Coalesce the prefetch once per saveMessages batch, skip it during initial sync and recovery, and rely on the negative cache and shared index from contacts-resolver-full-enumeration. Effort S.
- **Abandoned PendingAction rows are never pruned or surfaced, are loaded by every cleanup snapshot, and pin their conversation shells** (`esc-chatmail/Services/PendingActions/PendingActionProcessor.swift:481`). Only completed rows are cleaned up, and nothing in the UI calls the abandoned-action APIs or observes .pendingActionFailed. Fix: Prune abandoned rows older than 30 days in a maintenance pass, or surface them through the existing query API. Narrow the empty-conversation protection set to live statuses, but keep ConversationMerger retargeting every row. Effort S.
- **MessageListPaginator retains every persisted/excluded/unprocessable/gone ID across the run although callers read only counts and failure IDs** (`esc-chatmail/Services/Sync/MessageListPaginator.swift:165`). fetchAndProcess merges every page's ID buckets into a run-wide report, but callers read only counts and failure IDs. Fix: Keep counts for the non-failure buckets at the paginator level, and retain IDs only for failures. Effort S.
- **No view observes SyncEngine.uiState, and the initial-sync progress fraction saturates at 91-98% while paging** (`esc-chatmail/Services/Sync/InitialSyncOrchestrator.swift:349`). uiState has no consumer outside Services/Sync. Fix: Use profile.messagesTotal or resultSizeEstimate as the denominator, and show a lightweight 'Loading older mail' banner through a pure XPolicy. Effort S.
- **Missed-message reconciliation resume cursors pile up in UserDefaults while lastSuccessfulSyncTime is stale for more than 24 h** (`esc-chatmail/Services/Sync/SyncReconciliation.swift:262`). The query epoch is unquantized, so the exact-query guard almost never matches and a new overflow cursor is appended. Fix: Keep one cursor per window: replace instead of appending, or anchor the epoch to startedAt. Effort S.
- **Every merged save's Conversation IDs are fetched, snapshotted and inserted on main even when they sort far past the window** (`esc-chatmail/ViewModels/ConversationListViewModel+ChangeObservation.swift:179`). handleSiblingContextSave batch-fetches every changed conversation with a prefetch, then builds snapshots and does O(W) inserts before the trim drops them. Fix: Skip rows that are not in itemsByID and sort after the tail while the window is full, and set hasLoadedAllConversationWindow = false whenever something is skipped. Optionally narrow the fetch predicate to the window's IDs, pinned rows, or rows at or after the tail's date. Effort S.
- **The per-launch list-title repair re-materializes every message of multi-sender bare-List-Id lists on every launch** (`esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift:431`). Every listId conversation is fetched as a full row each launch. Fix: Use a dictionary-fetch scan, a per-conversation DISTINCT sender pre-check, and call the upgrade only when it can succeed. Factor the eligibility test out of singleSenderDisplayName so both share one definition. Effort S.
- **Each persisted message runs its own fetch for its Label objects** (`esc-chatmail/Services/Sync/Persistence/MessagePersister+Creation.swift:144`). createNewMessage and the update path call fetchLabelsByIds per message, which always goes to SQLite. Fix: Resolve Labels once per saveMessages call into an objectID dictionary, or keep a validated userInfo cache. Effort S.
- **Resolving a Message.id uniqueness conflict costs O(conversation size) and nil-overwrites columns, but no production path triggers one** (`esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld/ESCChatmail 6.xcdatamodel/contents:167-171`). Under the object-trump merge policy, a save-time Message.id conflict re-faults the old row's conversation and overwrites stored columns with nils. Fix: No code change. Pin the guarantee with a .sqlite test and a comment explaining why the lookup must precede every insert. Effort S.

### Web

- **Every web sync reads the whole people table up to three times and opens wide rw transactions just to check latched gates** (`web/src/sync/participantSetRepair.ts:233`). Each runSync opens display-name, participant-set and subject repair rw transactions over many tables only to read flags or signatures, and buildPersistContext reads people and labels again. Fix: Check flags and signatures in a readonly syncState transaction first, then open the rw transaction and re-check. Maintain the HME set or hash incrementally, and compute PersistContext once per sync. Effort S.
- **Each web blob prune check loads every blob row, and over budget it bulkGets every attachment** (`web/src/db/blobs.ts:204`). Every 20th out-of-transaction putBlob, the prune runs orderBy(lastAccessAt).toArray() and sums the sizes before deciding anything, adding latency to user-triggered downloads. Fix: Keep a running byte total in syncState, walk with a cursor and stop early, store an evictable flag on the row, and run the prune off the awaited path. Effort S.
- **Eight declared web Dexie indexes are never queried but are maintained on every write** (`web/src/db/schema.ts:45`). messages.gmThreadId, rfcMessageId, *labelIds (multiEntry), internalDate, conversations.[participantHash+isArchived+lastMessageDate], attachments.contentId, msgParticipants.[messageId+kind] and abandonedMessages.retryCount have no readers. Fix: Drop them in the same new Dexie version as the other web index changes, but keep [participantHash+isArchived+lastMessageDate] for the epoch lookup in non-inbox-arrival-epoch-growth. Effort S.
- **Web abandoned pending actions and terminal abandoned-message tombstones are never deleted and are fully scanned on a schedule** (`web/src/outbox/pendingActions.ts:279`). Only completed pendingActions are swept, and reconcileLabels reads the whole table every 30 min. Fix: Age out abandoned actions and old tombstones, and replace the toArray scans with indexed reads that keep the null-disjunct semantics. Effort S.

## Suggested order

Cheap fixes that stop permanent loss go first. A scale harness lands before the refactors that change SQL plans. Every schema change is batched into one model version.

1. **Stop silent and permanent loss.** Chunk archive and spam `batchModify`, re-queuing only abandoned rows under a day old. Make the attachment orphan sweep fail closed. Revive the dead out-of-space classifier as a shared predicate. Turn the store-load ladder into an allow-list with a real retry. Surface abandoned pending actions. All of these are small, none needs a schema change, and some loss is already reachable at S1.
2. **Bound the re-sync blast radius.** Bound the re-initial-sync window and freeze it at the first attempt. In history recovery, cap only the install-time branch. Refresh each page's saved objects in the sync context after the page save, but do not `reset()` it, and do not call `refreshAllObjects()` every page, which re-faults the hubs quadratically. Chunk the completion retry. Drop the run-wide ID arrays. This defuses the re-sign-in crash loop before the larger checkpoint work.
3. **Fix the web breakers.** Add a continuation token that is staged only on advancing slices, chunk and resume the participant repair, and page the incremental fetch. The web codebase is independent, so this can run in parallel with steps 1 and 2.
4. **Build the SQLite scale harness.** Seed an S2-shaped SQLite store once in `.sqlite` mode. Assert `EXPLAIN QUERY PLAN` output, `hasFault(forRelationshipNamed:)` on the hubs, and registered-object bounds. Revert-check each later fix against it.
5. **Move work off the main thread and switch to objectID predicates.** This needs no schema change. Archive, spam and star go to a background context under the rollup serializer. The chat-open snapshot, header-name loads and person fan-out move off main. Use the objectID form of `visibleInChat` for permanent IDs only. These are the biggest visible hitches at S2/S3.
6. **Handle a full disk end to end.** Make ENOSPC a run-level abort, and back off the sync loop with a storage message. These two must ship together, or the abort turns into a refetch every 60 seconds.
7. **Reclaim space and stop backing up re-downloadable content.** Build the deleted-file plan at post time from live values, and check for a live row before unlinking. Exclude Messages, Previews, Avatars and Backups from backup, and flag Attachments per file. Prune store backups. Move sign-out deletion onto tombstone renames.
8. **Add durable resume points and honor background budgets.** Give initial sync and recovery checkpoints that carry the frozen window and the accumulated failure IDs. Keep the missed-message list call under app refresh, but defer the fetches it triggers. Add shared 429 pacing.
9. **Move maintenance off latency paths.** Delete `removeDuplicateMessages`. Register maintenance tasks so expiration and sign-out can cancel them. Retire VACUUM, keeping a no-op handler for one release. Run the cadence passes as an exclusive maintenance run after `.syncCompleted`.
10. **Cut one model version, ESCChatmail 7.** Every index change needs a `versionHashModifier`, or it silently never migrates. Drop the duplicate `byIdIndex` and the dead indexes; drop `byIsUnreadIndex` and `byInternalDateIndex` only after step 5. Add a `Conversation.id` index and a `(conversation, isUnread)` index. Denormalize system-label flags onto Message, remove inverse maintenance for the self-Person edge, and add a `bodyEvicted` marker.
11. **Bound rollups and list paging.** Gather rollup inputs from bounded queries, including the newest-first preview walk, with a dirty-object overlay. Page the conversation list by keyset. Treat transcript keyset paging as its own step.
12. **Add retention tiers.** Evict HTML bodies, with the `bodyEvicted` marker opening the recovery gate. Download attachments lazily. Decide epoch semantics for both platforms.
13. **Treat Contacts as an index, not a scan.** One generation-fenced, normalized email-to-identifier index plus a negative cache serves the resolver, autocomplete and self-alias checks.
14. **Bump the web Dexie version once.** Batch the new web indexes, the index drops and body budgeting into a single `this.version(n)` upgrade.
15. **Bound the remaining in-memory structures** whenever the surrounding code is touched.

## Already sound

These held up under verification and do not need work:

- **Write-path identity lookups are indexed.** `Message.id` is constraint-unique and indexed, Person emails are prefetched once per batch, and conversation routing uses `byParticipantHashAndArchivedIndex`. Per-message persist cost is flat in store size, apart from the hub faults.
- **First-install initial sync is small and bounded.** It covers about five minutes of mail, streams 500-ID pages, fetches in batches of 50 at bounded concurrency, and saves each page with its rollups and a pre-scan watermark.
- **Incremental history slices are durable.** Each slice holds at most 10x500 records and stages its continuation token in `foregroundHistory.v1`. The cursor advances only on a terminal slice, so a 20k-record backlog drains in about four runs.
- **The cursor, failure ledger and counter commit atomically.** Save failures roll back, quota and auth errors abort with no verdicts, and cancellation propagates.
- **The failure ledger is bounded.** Deferred rows are replaced every run, abandoned rows drain 50 per sync with backoff, and rows are deleted after 5 attempts.
- **The chat transcript window is capped at 300 rows** in both directions, and row caches are pruned to the window, so memory per open chat stays flat even at the top of a 20k-message chat.
- **The conversation list has no FRC and applies changes incrementally.** Saves that only touch Message, Attachment or Label rows are rejected cheaply, and window SQL takes about 1-2 ms at 30k conversations.
- **In-memory caches have count and byte limits**, so resident cache memory stays flat from S1 to S3. The two exceptions are listed as items above.
- **Launch before the first frame is constant-cost.** The S3 store opens in 3-4 ms, and additive or index migrations run in place in 0.02-0.11 s.
- **SQLite free pages and the WAL are handled by Core Data.** The store is `auto_vacuum=INCREMENTAL`, and post-save maintenance runs `incremental_vacuum` and `wal_checkpoint(TRUNCATE)`. The freelist is about 0.4% at S3.
- **The action and send queues stay small.** `markRead` is chunked at 1,000 IDs, completed pending actions are deleted every run, and `OutboundSendMutationRecord`s are consumed atomically with the echo.
- **Bounded disk caches.** `DiskImageCache` (100 MB, 7-day TTL) and the snapshot cache (50 MB) live in Caches, and the HTML orphan sweep skips when the ID set cannot be read.
- **Web keyset windows and blob budget.** The web transcript and list are keyset range reads, the list is virtualized, and attachment blobs are LRU-budgeted.

## Checked and found not to be a problem

These were raised during the audit and refuted. They are listed so nobody re-investigates them.

- **History recovery does not normally re-list the mailbox.** It starts at `lastSuccessfulSyncTime` minus 10 minutes. The install-time fallback is reached only after teardown clears that key, which is the breaker item above.
- **The 30-day initial-sync fallback is not the normal window.** It is reachable only through `FreshInstallHandler`'s indeterminate-keychain backstop.
- **`localModifiedAt` is cleared.** `PendingActionProcessor.clearLocalModifications` resets it when its action succeeds.
- **The participant-set split migration does not re-run on fresh installs.** It latches on a near-empty store, and the flag survives sign-out. It costs real time only for upgraders with a populated pre-V2 store.
- **The V6 display-name refresh is effectively upgrade-only.** It remains a hazard only if its key is ever bumped.
- **Lightweight migrations do not rebuild tables on the main thread.** Additive and index changes ran in place in 0.02-0.11 s at S3.
- **Foreground sync does not park behind a BG VACUUM.** The run is skipped as "already in progress".
- **Optimistic sends cannot trigger a `Message.id` uniqueness conflict.** Optimistic rows use UUIDs, and the persister looks up before inserting.
- **`ParticipantRollupDependencyTracker.emailGenerations` is bounded** by distinct invalidated emails and cleared by `invalidateAll`.
- **The Drive metadata cache does not leak across accounts.** Its fetches carry no credentials, so the cached values are public-link results.
- **Deleted Gmail labels are pruned.** `removeStaleLabels` handles that. Only the "new labels are never fetched" half stands, as a hygiene item.
- **Avatar storage does not grow with Person count.** Avatars come only from device Contacts thumbnails and overwrite in place.
- **Pruning `RenderedMessageCache` generation entries per key would be unsafe** (ABA with cancelled waiters). Threshold-triggered global-generation compaction is the safe alternative.
- **Archive and spam ID sets must not be narrowed to INBOX rows.** `localModifiedAt` blocks remote label replay during the pending window, SPAM must reach every message, and sending all IDs self-heals INBOX drift.
- **Two counter-claims were themselves refuted by measurement.** `addToLabels` and `removeFromLabels` do fire the inverse `Label.messages` fault: 70k-319k rows were loaded. A fetch-index-only model edit does not reach existing stores without a `versionHashModifier`.
