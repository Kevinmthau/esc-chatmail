// Loads, sanitizes and caches a message's HTML body plus its inline cid image
// Blobs. Sanitized documents are cached per messageId+mode+body-digest in a
// small module LRU; attachment downloads are bounded, deduplicated in flight
// and capped by a wall-clock budget so a stalled image cannot block the body.

import { useCallback, useEffect, useState } from 'react'
import { BlobQuotaExceededError, getBlob, putBlob } from '@/db/blobs'
import { getDB, type ChatmailDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'
import { getAttachment } from '@/gmail/endpoints'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { sha256Hex } from '@/identity/hash'
import { useAccountLiveQuery } from '@/live/hooks'
import { queryMessageBody } from '@/live/queries'
import { base64UrlDecodeToBytes } from '@/mime/decode'
import {
  sanitizeEmailHtml,
  type EmailRenderMode,
  type SanitizedEmailHtml,
} from './sanitizeEmailHtml'

const SANITIZE_CACHE_MAX = 20
/** Local blob-store lookups run in parallel up to this many at a time. */
const CID_LOOKUP_CONCURRENCY = 8
/** Inline-image downloads run in parallel up to this many at a time. */
const CID_DOWNLOAD_CONCURRENCY = 4
/**
 * Wall-clock budget for resolving ALL of a message's cid images. Whatever has
 * not arrived by then is dropped from this render (the download keeps running
 * and lands in the blob store, so Retry or the next open picks it up) — one
 * hung attachment request must never leave the body permanently unrendered.
 */
const CID_RESOLUTION_BUDGET_MS = 15_000

let cidResolutionBudgetMs = CID_RESOLUTION_BUDGET_MS

/** Test hook: shrink the cid budget; pass null to restore the default. */
export function setCidResolutionBudgetForTests(ms: number | null): void {
  cidResolutionBudgetMs = ms ?? CID_RESOLUTION_BUDGET_MS
}

export interface EmailHtmlState {
  status: 'loading' | 'ready' | 'failed'
  html?: string
  cidBlobs?: Record<string, Blob>
  retry: () => void
}

// --- Broker registration ----------------------------------------------------

// The app shell registers its AuthBroker once at startup; without one, missing
// attachment blobs simply stay unresolved (images render blank, never throw).
let attachmentBroker: TokenBroker | null = null

export function setEmailAttachmentBroker(broker: TokenBroker | null): void {
  attachmentBroker = broker
}

// --- Sanitize LRU -----------------------------------------------------------

const sanitizeCache = new Map<string, Promise<SanitizedEmailHtml>>()

/**
 * The body digest is part of the key: sync rewrites bodies (a truncated body
 * replaced by the full one via fetchLargeBody, or a re-persist through the
 * abandoned drain), and a messageId-only key would serve the stale document
 * until 20 other messages evicted it.
 */
function cacheKey(messageId: string, mode: EmailRenderMode, rawHtml: string): string {
  return `${messageId}|${mode}|${sha256Hex(rawHtml)}`
}

function cachedSanitize(
  messageId: string,
  mode: EmailRenderMode,
  rawHtml: string,
): Promise<SanitizedEmailHtml> {
  const key = cacheKey(messageId, mode, rawHtml)
  const hit = sanitizeCache.get(key)
  if (hit !== undefined) {
    // Refresh recency: Map iterates in insertion order.
    sanitizeCache.delete(key)
    sanitizeCache.set(key, hit)
    return hit
  }

  const promise = sanitizeEmailHtml(rawHtml, { mode })
  promise.catch(() => sanitizeCache.delete(key))
  sanitizeCache.set(key, promise)
  while (sanitizeCache.size > SANITIZE_CACHE_MAX) {
    const oldest = sanitizeCache.keys().next().value
    if (oldest === undefined) break
    sanitizeCache.delete(oldest)
  }
  return promise
}

export function invalidateEmailHtmlCache(messageId: string): void {
  const prefix = `${messageId}|`
  for (const key of [...sanitizeCache.keys()]) {
    if (key.startsWith(prefix)) sanitizeCache.delete(key)
  }
}

// --- cid → Blob resolution --------------------------------------------------

const inFlightDownloads = new Map<string, Promise<Blob | null>>()

async function downloadAttachmentBlob(db: ChatmailDB, att: AttachmentRow): Promise<Blob | null> {
  const broker = attachmentBroker
  if (broker === null || att.gmailAttachmentId === '') return null

  const existing = inFlightDownloads.get(att.id)
  if (existing !== undefined) return existing

  const task = (async (): Promise<Blob | null> => {
    try {
      const response = await getAttachment(broker, att.messageId, att.gmailAttachmentId)
      const bytes = base64UrlDecodeToBytes(response.data)
      if (bytes === null) return null
      const blob = new Blob([bytes.buffer as ArrayBuffer], {
        type: att.mimeType.length > 0 ? att.mimeType : 'application/octet-stream',
      })
      try {
        await putBlob(db, att.id, blob)
      } catch (error) {
        if (!(error instanceof BlobQuotaExceededError)) throw error
        // Storage is full even after eviction: render the image from memory
        // this once and leave the row un-cached so it is fetched again later.
        await db.attachments
          .update(att.id, { lastDownloadFailedAt: Date.now() })
          .catch(() => undefined)
        return blob
      }
      await db.attachments.update(att.id, { state: 'downloaded', byteSize: blob.size })
      return blob
    } catch {
      await db.attachments
        .update(att.id, { lastDownloadFailedAt: Date.now() })
        .catch(() => undefined)
      return null
    } finally {
      inFlightDownloads.delete(att.id)
    }
  })()

  inFlightDownloads.set(att.id, task)
  return task
}

/** Resolves to `null` when `task` has not settled by `deadline` (epoch ms). */
function withDeadline(task: Promise<Blob | null>, deadline: number): Promise<Blob | null> {
  const remaining = deadline - Date.now()
  if (remaining <= 0) return Promise.resolve(null)
  return new Promise<Blob | null>((resolve) => {
    const timer = setTimeout(() => resolve(null), remaining)
    const settle = (blob: Blob | null): void => {
      clearTimeout(timer)
      resolve(blob)
    }
    task.then(settle, () => settle(null))
  })
}

/** Runs `worker` up to `limit` times in parallel (never more than `size`). */
async function runBounded(limit: number, size: number, worker: () => Promise<void>): Promise<void> {
  await Promise.all(Array.from({ length: Math.min(limit, size) }, () => worker()))
}

/**
 * Resolves every cid the sanitizer collected to its bytes, in two passes.
 *
 * 1. Local: one blob-store lookup per cid, uncapped. These are cheap indexed
 *    reads with no network cost, and a count cap here silently dropped the
 *    images past it from a long newsletter forever — Retry re-ran the same
 *    fixed prefix, and the frame strips the src of any cid it was not given.
 * 2. Network: only the cids with no local copy, bounded to
 *    CID_DOWNLOAD_CONCURRENCY in flight and to the shared wall-clock budget.
 *    Once the budget is spent, no further download *starts* — firing hundreds
 *    of requests whose bytes this render can no longer use is exactly the storm
 *    a cap was meant to prevent. Downloads that did start keep running and land
 *    in the blob store, so pass 1 of the next open picks them up: every reopen
 *    makes forward progress instead of freezing at the same prefix.
 */
async function resolveCidBlobs(
  db: ChatmailDB,
  messageId: string,
  cids: string[],
): Promise<Record<string, Blob>> {
  const resolved: Record<string, Blob> = {}
  if (cids.length === 0) return resolved
  const deadline = Date.now() + cidResolutionBudgetMs

  const missing: Array<{ cid: string; att: AttachmentRow }> = []
  let nextCid = 0
  const lookupWorker = async (): Promise<void> => {
    for (;;) {
      const cid = cids[nextCid++]
      if (cid === undefined) return
      const att = await db.attachments
        .where('[messageId+contentId]')
        .equals([messageId, cid])
        .first()
      if (att === undefined) continue

      const blob = await getBlob(db, att.id)
      if (blob !== null) resolved[cid] = blob
      else missing.push({ cid, att })
    }
  }
  await runBounded(CID_LOOKUP_CONCURRENCY, cids.length, lookupWorker)

  let nextMissing = 0
  const downloadWorker = async (): Promise<void> => {
    for (;;) {
      const pending = missing[nextMissing++]
      if (pending === undefined || Date.now() >= deadline) return
      const blob = await withDeadline(downloadAttachmentBlob(db, pending.att), deadline)
      if (blob !== null) resolved[pending.cid] = blob
    }
  }
  await runBounded(CID_DOWNLOAD_CONCURRENCY, missing.length, downloadWorker)

  return resolved
}

// --- Hook -------------------------------------------------------------------

interface HookResult {
  key: string
  failed: boolean
  html?: string
  cidBlobs?: Record<string, Blob>
}

export function useEmailHtml(messageId: string, mode: EmailRenderMode): EmailHtmlState {
  const [attempt, setAttempt] = useState(0)
  const [result, setResult] = useState<HookResult | null>(null)

  // undefined while the live query resolves; null when the message has no HTML body.
  const bodyHtml = useAccountLiveQuery((db) => queryMessageBody(db, messageId), [messageId])

  const expectedKey = `${messageId}|${mode}|${attempt}`

  useEffect(() => {
    if (bodyHtml === undefined) return
    if (bodyHtml === null) {
      setResult({ key: expectedKey, failed: true })
      return
    }

    let cancelled = false
    void (async () => {
      try {
        const db = getDB()
        const sanitized = await cachedSanitize(messageId, mode, bodyHtml)
        const cidBlobs = await resolveCidBlobs(db, messageId, sanitized.cids)
        if (!cancelled) {
          setResult({ key: expectedKey, failed: false, html: sanitized.html, cidBlobs })
        }
      } catch {
        if (!cancelled) setResult({ key: expectedKey, failed: true })
      }
    })()
    return () => {
      cancelled = true
    }
  }, [messageId, mode, attempt, bodyHtml, expectedKey])

  const retry = useCallback(() => {
    invalidateEmailHtmlCache(messageId)
    setAttempt((current) => current + 1)
  }, [messageId])

  if (result === null || result.key !== expectedKey) {
    return { status: 'loading', retry }
  }
  if (result.failed) {
    return { status: 'failed', retry }
  }
  return { status: 'ready', html: result.html, cidBlobs: result.cidBlobs, retry }
}
