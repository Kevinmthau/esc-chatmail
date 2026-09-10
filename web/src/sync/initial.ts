// Initial full sync. Port of InitialSyncOrchestrator.swift:
// profile + sendAs aliases → labels → paged list-sync (500/page) with
// per-page fetch/persist/rollup so an interruption leaves a consistent,
// presentable store. The history cursor (profile.historyId captured at the
// START of sync) is written only at the very end, and only once no message is
// still failing — or once the stuck ids have been handed to the abandoned
// registry, so a permanent failure cannot wedge the account in full-resync
// forever.

import { getLastSuccessfulSyncAt, setLastSuccessfulSyncAt, setSyncProgress } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import type { AccountRow } from '@/db/types'
import { isHideMyEmailDisplayName, normalizeEmail } from '@/identity/normalizeEmail'
import { rollupConversation } from '@/rollup/rollup'
import { persistAccountAliases } from './aliases'
import { depsNow, depsRandom, depsSleep, makeFetchLargeBody, type SyncDeps } from './deps'
import { fetchMessagesBounded } from './fetch'
import { recordSyncFailure, shouldAdvanceHistoryId } from './abandoned'
import {
  applyPersist,
  preparePersist,
  retryableFailurePlanIds,
  type PersistContext,
} from './persist'
import { SYNC_QUERY_EXCLUSIONS } from './reconcile'
import { recordUnprocessableMessages, unprocessablePlanIds } from './unprocessable'

export const INITIAL_SYNC_PAGE_SIZE = 500
/** Backfill covers mail from 5 minutes before install (timestampBufferSeconds). */
export const INITIAL_SYNC_BUFFER_MS = 300_000

export interface InitialSyncResult {
  mode: 'initial'
  messagesProcessed: number
  failedIds: string[]
  historyIdAdvanced: boolean
}

/** Rolls up every touched conversation in one rw transaction. */
export async function rollupConversations(
  db: ChatmailDB,
  conversationIds: ReadonlySet<string>,
  now: number,
): Promise<void> {
  if (conversationIds.size === 0) return
  await db.transaction('rw', db.messages, db.conversations, async () => {
    for (const id of conversationIds) {
      await rollupConversation(db, id, now)
    }
  })
}

export interface ListSyncPagesResult {
  processedCount: number
  failedIds: string[]
}

/**
 * Shared paged list-sync used by initial sync and history recovery: for each
 * page of `query` results, fetch full messages with bounded concurrency,
 * persist, and roll up the page's touched conversations before moving on.
 * `phaseLabel` scopes the crash-injection hook (`<label>:page:<n>`).
 */
export async function listSyncPages(
  deps: SyncDeps,
  ctx: PersistContext,
  query: string,
  phaseLabel: string,
): Promise<ListSyncPagesResult> {
  const { db, api } = deps
  const failedIds: string[] = []
  let processedCount = 0
  let pageToken: string | undefined
  let pageIndex = 0

  do {
    const params =
      pageToken === undefined
        ? { q: query, maxResults: INITIAL_SYNC_PAGE_SIZE }
        : { q: query, maxResults: INITIAL_SYNC_PAGE_SIZE, pageToken }
    const page = await api.listMessages(params)
    const ids = (page.messages ?? []).map((m) => m.id)

    if (ids.length > 0) {
      const fetchResult = await fetchMessagesBounded(api, ids, {
        sleep: depsSleep(deps),
        random: depsRandom(deps),
      })
      failedIds.push(...fetchResult.failed.map((f) => f.id))

      const plans = await preparePersist(fetchResult.fetched, ctx)
      failedIds.push(...retryableFailurePlanIds(plans))
      // applyPersist silently skips unparseable plans. Park them in the
      // abandoned registry instead of dropping them without a trace: this path
      // is shared with history recovery, where the lookback window closes
      // within minutes and the message would otherwise be lost for good with
      // the run still reporting a clean success.
      await recordUnprocessableMessages(db, unprocessablePlanIds(plans), depsNow(deps))
      const applied = await applyPersist(db, plans, depsNow(deps))
      failedIds.push(...applied.retryableMessageIds)
      processedCount += applied.persistedMessageIds.size

      // Per-page rollup + the page's messages persist together, so killing
      // the sync between pages leaves every saved page fully presentable.
      await rollupConversations(db, applied.touchedConversationIds, depsNow(deps))

      await setSyncProgress(db, {
        phase: 'initial',
        fetchedCount: processedCount,
        ...(page.resultSizeEstimate !== undefined
          ? { totalEstimate: page.resultSizeEstimate }
          : {}),
      })
    }

    pageIndex += 1
    await deps.hooks?.onPhase?.(`${phaseLabel}:page:${pageIndex}`)
    pageToken = page.nextPageToken
  } while (pageToken !== undefined)

  return { processedCount, failedIds }
}

export function initialSyncQuery(installTs: number): string {
  const startSec = Math.floor((installTs - INITIAL_SYNC_BUFFER_MS) / 1000)
  return `after:${startSec} ${SYNC_QUERY_EXCLUSIONS}`
}

export async function buildPersistContext(
  deps: SyncDeps,
  account: AccountRow,
): Promise<PersistContext> {
  const [labelRows, people] = await Promise.all([
    deps.db.labels.toArray(),
    deps.db.people.toArray(),
  ])
  const knownLabelIds = labelRows.length > 0 ? new Set(labelRows.map((l) => l.id)) : null
  return {
    myAliases: new Set(account.aliases),
    hideMyEmailAddresses: new Set(
      people
        .filter((person) => isHideMyEmailDisplayName(person.displayName))
        .map((person) => normalizeEmail(person.email))
        .filter((email) => email !== ''),
    ),
    sendAsAliases: account.sendAsAliases,
    knownLabelIds,
    fetchLargeBody: makeFetchLargeBody(deps.api),
  }
}

export async function runInitialSync(deps: SyncDeps): Promise<InitialSyncResult> {
  const { db, api } = deps
  await setSyncProgress(db, { phase: 'initial', fetchedCount: 0 })

  // Phase 1: profile + sendAs aliases. The historyId captured HERE (before any
  // message is listed) is what gets stored at the end: changes racing the
  // backfill are then re-covered by the first incremental sync.
  const [profile, sendAsList] = await Promise.all([api.getProfile(), api.listSendAs()])
  const startHistoryId = profile.historyId
  await persistAccountAliases(db, deps.accountEmail, sendAsList, depsNow(deps))
  const account = await db.accounts.get(deps.accountEmail)
  if (account === undefined) throw new Error('Account row missing after alias persist')

  // Phase 2: labels.
  const labels = await api.listLabels()
  if (labels.length > 0) {
    await db.labels.bulkPut(labels.map((l) => ({ id: l.id, name: l.name })))
  }

  const ctx = await buildPersistContext(deps, account)

  // Phase 3: paged fetch/persist/rollup.
  const query = initialSyncQuery(account.installTs)
  const result = await listSyncPages(deps, ctx, query, 'initial')

  // Phase 4: completion policy. The cursor advances on a clean run — or, after
  // MAX_CONSECUTIVE_SYNC_FAILURES backfills stuck on the same ids, once those
  // ids are parked in the abandoned registry. Without that escape hatch a
  // single permanently-failing message pins historyId at '' forever, so
  // runIncrementalSync routes back here on every tick and re-lists and
  // re-fetches the whole install-to-now window, indefinitely (deadlock
  // prevention, matching runHistoryRecovery).
  const hadFailures = result.failedIds.length > 0
  if (hadFailures) await recordSyncFailure(db, result.failedIds)
  const now = depsNow(deps)
  const historyIdAdvanced = await shouldAdvanceHistoryId(db, hadFailures, now)

  if (historyIdAdvanced) {
    await db.transaction('rw', db.accounts, async () => {
      const fresh = await db.accounts.get(deps.accountEmail)
      if (fresh !== undefined) {
        await db.accounts.put({ ...fresh, historyId: startHistoryId })
      }
    })
    if (!hadFailures) await setLastSuccessfulSyncAt(db, now)
  }

  if (hadFailures) {
    const suffix = historyIdAdvanced
      ? 'abandoned after repeated failures; sync will continue'
      : 'failed to fetch; initial sync will retry'
    await setSyncProgress(db, {
      phase: 'idle',
      fetchedCount: result.processedCount,
      lastError: `${result.failedIds.length} messages ${suffix}`,
    })
  } else {
    await setSyncProgress(db, {
      phase: 'idle',
      fetchedCount: result.processedCount,
      lastSyncAt: await getLastSuccessfulSyncAt(db),
    })
  }

  return {
    mode: 'initial',
    messagesProcessed: result.processedCount,
    failedIds: result.failedIds,
    historyIdAdvanced,
  }
}
