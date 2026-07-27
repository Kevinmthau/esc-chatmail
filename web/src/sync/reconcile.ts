// Sync reconciliation: the safety net for dropped history events.
// Port of SyncReconciliation.swift, simplified per plan:
// - missed-message check: single capped list query every sync (no resumable
//   cursor), lookback max(lastSync - 5min, now - 24h) never before install;
// - label reconciliation: fixed 30-minute TTL (kv.labelReconciledAt) instead
//   of the iOS dual TTL; last-24h ids (max 100), metadata GETs at bounded
//   concurrency, INBOX/UNREAD drift repair that never overrides fresh
//   localModifiedAt and never re-adds INBOX over a local SPAM label.

import type { ChatmailDB } from '@/db/schema'
import { getLabelReconciledAt, getLastSuccessfulSyncAt } from '@/db/kv'
import { GmailApiError } from '@/gmail/errors'
import { mapWithConcurrency } from './concurrency'
import type { GmailSyncApi } from './deps'
import { applyFastUpdateForExistingMessage, LOCAL_MODIFICATION_MAX_AGE_MS } from './persist'

export const LABEL_RECONCILE_TTL_MS = 30 * 60 * 1000
/**
 * How recently a 'completed' pendingAction must have been completed for it to
 * block label reconciliation. Only covers the drain-completes-mid-pass race:
 * the phase-1 metadata fetch takes seconds, not minutes.
 */
export const COMPLETED_ACTION_BLOCK_WINDOW_MS = 5 * 60 * 1000
export const MISSED_MESSAGE_BUFFER_MS = 5 * 60 * 1000
export const MISSED_MESSAGE_LOOKBACK_CAP_MS = 24 * 60 * 60 * 1000
export const MISSED_MESSAGE_FALLBACK_MS = 60 * 60 * 1000
export const MISSED_MESSAGE_PAGE_SIZE = 500
export const LABEL_RECONCILE_MAX_MESSAGES = 100
export const RECONCILE_CONCURRENCY = 8

export const SYNC_QUERY_EXCLUSIONS = '-label:spam -label:drafts -label:trash'

/** The `after:` cutoff (epoch ms) for the missed-message check. */
export function missedMessageStartMs(lastSyncAt: number, installTs: number, now: number): number {
  let start =
    lastSyncAt > 0 ? lastSyncAt - MISSED_MESSAGE_BUFFER_MS : now - MISSED_MESSAGE_FALLBACK_MS
  start = Math.max(start, now - MISSED_MESSAGE_LOOKBACK_CAP_MS)
  if (installTs > 0) start = Math.max(start, installTs - MISSED_MESSAGE_BUFFER_MS)
  return start
}

/**
 * Lists recent Gmail ids (single page, capped) and returns the ones missing
 * locally. Runs every sync — it is the cheap half of reconciliation.
 */
export async function findMissedMessageIds(
  db: ChatmailDB,
  api: GmailSyncApi,
  installTs: number,
  now: number,
): Promise<string[]> {
  const lastSyncAt = await getLastSuccessfulSyncAt(db)
  const startSec = Math.floor(missedMessageStartMs(lastSyncAt, installTs, now) / 1000)
  const response = await api.listMessages({
    q: `after:${startSec} ${SYNC_QUERY_EXCLUSIONS}`,
    maxResults: MISSED_MESSAGE_PAGE_SIZE,
  })
  const ids = (response.messages ?? []).map((m) => m.id)
  if (ids.length === 0) return []

  const presentKeys = await db.messages.where('id').anyOf(ids).primaryKeys()
  const present = new Set(presentKeys)
  // Ids already owned by the abandoned registry are excluded: the drain owns
  // their retry budget, and unparseable tombstones can never be persisted, so
  // re-fetching them here would repeat forever on every single sync.
  const abandonedKeys = await db.abandonedMessages.where('gmailMessageId').anyOf(ids).primaryKeys()
  const abandoned = new Set(abandonedKeys)
  return ids.filter((id) => !present.has(id) && !abandoned.has(id))
}

interface RemoteLabelState {
  id: string
  hasInbox: boolean
  isUnread: boolean
}

export interface LabelReconcileResult {
  /** True when every metadata fetch succeeded (TTL only records then). */
  completed: boolean
  touchedConversationIds: Set<string>
  repairedCount: number
  skippedCount: number
}

/**
 * TTL-gated INBOX/UNREAD drift repair over the last 24h of mail (max 100
 * messages, metadata format, bounded concurrency). Returns null when the TTL
 * has not lapsed. The caller records kv.labelReconciledAt only when the
 * result is `completed` and the sync's save succeeded.
 */
export async function reconcileLabels(
  db: ChatmailDB,
  api: GmailSyncApi,
  now: number,
  options: { concurrency?: number; force?: boolean } = {},
): Promise<LabelReconcileResult | null> {
  if (options.force !== true) {
    const last = await getLabelReconciledAt(db)
    if (last > 0 && now - last < LABEL_RECONCILE_TTL_MS) return null
  }

  const startSec = Math.floor((now - MISSED_MESSAGE_LOOKBACK_CAP_MS) / 1000)
  const response = await api.listMessages({
    q: `after:${startSec} ${SYNC_QUERY_EXCLUSIONS}`,
    maxResults: LABEL_RECONCILE_MAX_MESSAGES,
  })
  const ids = (response.messages ?? []).map((m) => m.id)

  const result: LabelReconcileResult = {
    completed: true,
    touchedConversationIds: new Set(),
    repairedCount: 0,
    skippedCount: 0,
  }
  if (ids.length === 0) return result

  // Phase 1 (network, outside any transaction): fetch remote label state.
  const remote: RemoteLabelState[] = []
  const concurrency = Math.max(1, options.concurrency ?? RECONCILE_CONCURRENCY)
  await mapWithConcurrency(ids, concurrency, async (id) => {
    try {
      const message = await api.getMessage(id, 'metadata')
      const labels = message.labelIds ?? []
      remote.push({
        id,
        hasInbox: labels.includes('INBOX'),
        isUnread: labels.includes('UNREAD'),
      })
    } catch (error) {
      if (error instanceof GmailApiError && error.status === 404) {
        // Deleted server-side since the list call; nothing to reconcile.
        return
      }
      result.completed = false
    }
  })

  // Phase 2 (Dexie-only transaction): repair drift.
  await db.transaction('rw', db.messages, db.conversations, db.pendingActions, async () => {
    // The remote state above was fetched over a multi-second window OUTSIDE
    // any transaction, and the outbox drain is not serialized against sync
    // (different Web Lock). A drain can complete a local mutation in that
    // window: completeAction zeroes localModifiedAt, so the guard below no
    // longer protects the message, and applying the pre-fetched (now stale)
    // remote state would revert the just-completed mutation. Skip every
    // message currently targeted by a pending/processing/failed action, plus
    // 'completed' rows that were completed RECENTLY (i.e. could have raced this
    // pass's fetch). Older completed rows must NOT block: they are only swept
    // at the start of the next drain, and a drain only happens on a local
    // mutation or an 'online' event — so blocking them unconditionally
    // disables label repair for those ids until the user happens to act.
    // 'abandoned' rows are permanent and excluded so reconciliation can still
    // repair the drift they leave behind.
    const blockedIds = new Set<string>()
    const actionRows = await db.pendingActions.toArray()
    for (const row of actionRows) {
      if (row.status === 'abandoned') continue
      if (row.status === 'completed' && now - row.lastAttempt >= COMPLETED_ACTION_BLOCK_WINDOW_MS) {
        continue
      }
      if (row.messageId !== '') blockedIds.add(row.messageId)
      for (const id of row.messageIds) blockedIds.add(id)
    }

    for (const state of remote) {
      const local = await db.messages.get(state.id)
      if (local === undefined) {
        result.skippedCount += 1
        continue
      }

      if (blockedIds.has(state.id)) {
        result.skippedCount += 1
        continue
      }

      // Never override a fresh local mutation.
      if (
        local.localModifiedAt !== 0 &&
        now - local.localModifiedAt < LOCAL_MODIFICATION_MAX_AGE_MS
      ) {
        result.skippedCount += 1
        continue
      }

      const localHasInbox = local.labelIds.includes('INBOX')
      const localIsUnread = local.isUnread === 1
      let labelIds = local.labelIds

      if (state.hasInbox !== localHasInbox) {
        // Never re-add INBOX over a local SPAM label — user intent wins.
        if (state.hasInbox && local.labelIds.includes('SPAM')) {
          result.skippedCount += 1
          continue
        }
        labelIds = state.hasInbox ? [...labelIds, 'INBOX'] : labelIds.filter((id) => id !== 'INBOX')
      }

      const unreadDrift = state.isUnread !== localIsUnread
      if (unreadDrift) {
        labelIds = state.isUnread
          ? labelIds.includes('UNREAD')
            ? labelIds
            : [...labelIds, 'UNREAD']
          : labelIds.filter((id) => id !== 'UNREAD')
      }

      if (labelIds === local.labelIds && !unreadDrift) continue

      const isUnread: 0 | 1 = state.isUnread ? 1 : 0
      const updated = { ...local, labelIds, isUnread }
      await db.messages.put(updated)
      await applyFastUpdateForExistingMessage(
        db,
        updated.conversationId,
        updated,
        localHasInbox,
        localIsUnread,
      )
      result.repairedCount += 1
      result.touchedConversationIds.add(updated.conversationId)
    }
  })

  return result
}
