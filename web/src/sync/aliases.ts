// Send-as alias acceptance, dedup, and persistence. Port of the SendAsAlias
// struct helpers in Services/Send/SendAsAlias.swift plus the identity-alias
// set construction from InitialSyncOrchestrator.fetchProfileAndAliases /
// AliasManager.
//
// Two distinct alias sets exist (do not conflate them):
// - the SENDABLE set (SendAsAlias[]): aliases the user may send from
//   (accepted = primary OR verification 'accepted' OR (no status AND default));
// - the IDENTITY set (Set<string>): fully normalized addresses used to strip
//   self from participant sets (buildIdentityAliasSet).
//
// The db SendAsAlias row uses '' for "absent" displayName/verificationStatus
// (the iOS struct uses nil).

import type { ChatmailDB } from '@/db/schema'
import type { SendAsAlias } from '@/db/types'
import type { SendAsEntry } from '@/gmail/types'
import { extractEmail, normalizeEmail } from '@/identity/normalizeEmail'

/**
 * Header-level address normalization (SendAsAlias.normalizedAddress): extract
 * the bare address, trim, lowercase. Deliberately NOT the full Gmail
 * canonicalization — dots and plus-tags are preserved so distinct sendAs
 * aliases stay distinct. Gmail equivalence is a separate, explicit escape
 * hatch (see replyFrom.matchesGmailEquivalent).
 */
export function normalizedAliasAddress(raw: string): string {
  const extracted = extractEmail(raw) ?? raw
  return extracted.trim().toLowerCase()
}

/**
 * Whether an alias may be used as a send-from identity:
 * primary always; otherwise verificationStatus 'accepted' (case-insensitive);
 * a missing status falls back to isDefault (Gmail omits the status for the
 * primary/default address).
 */
export function isAcceptedForSending(alias: SendAsAlias): boolean {
  if (alias.isPrimary) return true
  if (alias.verificationStatus === '') return alias.isDefault
  return alias.verificationStatus.toLowerCase() === 'accepted'
}

/** Maps a Gmail sendAs entry to a sendable alias; null when unusable. */
export function fromGmailSendAs(entry: SendAsEntry): SendAsAlias | null {
  const alias: SendAsAlias = {
    email: normalizedAliasAddress(entry.sendAsEmail),
    displayName: entry.displayName?.trim() ?? '',
    isDefault: entry.isDefault === true,
    isPrimary: entry.isPrimary === true,
    verificationStatus: entry.verificationStatus?.trim() ?? '',
  }

  if (alias.email === '' || !isAcceptedForSending(alias)) return null
  return alias
}

function shouldPrefer(candidate: SendAsAlias, existing: SendAsAlias): boolean {
  if (candidate.isDefault !== existing.isDefault) return candidate.isDefault
  if (candidate.isPrimary !== existing.isPrimary) return candidate.isPrimary
  if (existing.displayName === '' && candidate.displayName !== '') return true
  return false
}

/**
 * Drops non-sendable aliases and deduplicates by normalized address,
 * preferring default > primary > has-display-name. First-seen order is kept.
 */
export function deduplicated(aliases: readonly SendAsAlias[]): SendAsAlias[] {
  const byAddress = new Map<string, SendAsAlias>()

  for (const alias of aliases) {
    if (!isAcceptedForSending(alias)) continue
    const key = normalizedAliasAddress(alias.email)
    if (key === '') continue

    const existing = byAddress.get(key)
    if (existing === undefined || shouldPrefer(alias, existing)) {
      byAddress.set(key, alias)
    }
  }

  return [...byAddress.values()]
}

/**
 * The sendable alias list from a Gmail sendAs response
 * (SendAsAlias.validAliases): filter to accepted, dedupe, and guarantee the
 * account email itself is present (inserted first, primary, default only when
 * no other default exists).
 */
export function validAliases(
  sendAsList: readonly SendAsEntry[],
  accountEmail?: string,
): SendAsAlias[] {
  const aliases = deduplicated(
    sendAsList.map(fromGmailSendAs).filter((alias): alias is SendAsAlias => alias !== null),
  )

  if (accountEmail !== undefined && accountEmail.trim() !== '') {
    const normalized = normalizedAliasAddress(accountEmail)
    if (!aliases.some((alias) => alias.email === normalized)) {
      aliases.unshift({
        email: normalized,
        displayName: '',
        isDefault: !aliases.some((alias) => alias.isDefault),
        isPrimary: true,
        verificationStatus: 'accepted',
      })
    }
  }

  return aliases
}

/** Default send-from alias: first default, else first primary, else first. */
export function defaultAlias(aliases: readonly SendAsAlias[]): SendAsAlias | null {
  return (
    aliases.find((alias) => alias.isDefault) ??
    aliases.find((alias) => alias.isPrimary) ??
    aliases[0] ??
    null
  )
}

/**
 * The identity alias set: fully normalized (Gmail-canonical) forms of the
 * account email plus every sendable alias. Feeds participant-set self-removal.
 */
export function buildIdentityAliasSet(
  accountEmail: string,
  sendAsList: readonly SendAsEntry[],
): Set<string> {
  const identitySet = new Set<string>()
  for (const raw of [accountEmail, ...validAliases(sendAsList, accountEmail).map((a) => a.email)]) {
    const normalized = normalizeEmail(raw)
    if (normalized !== '') identitySet.add(normalized)
  }
  return identitySet
}

export interface PersistedAliases {
  /** Identity alias set (normalized), as stored on the account row. */
  aliases: string[]
  /** Sendable aliases, as stored on the account row. */
  sendAsAliases: SendAsAlias[]
}

/**
 * Upserts both alias sets onto the account row. Existing sync state
 * (historyId, installTs) is preserved; a missing row is created with fresh
 * defaults. Compute happens before the transaction (Dexie tx-safety).
 */
export async function persistAccountAliases(
  db: ChatmailDB,
  accountEmail: string,
  sendAsList: readonly SendAsEntry[],
  now: number,
): Promise<PersistedAliases> {
  const sendAsAliases = validAliases(sendAsList, accountEmail)
  const aliases = [...buildIdentityAliasSet(accountEmail, sendAsList)]

  await db.transaction('rw', db.accounts, async () => {
    const existing = await db.accounts.get(accountEmail)
    if (existing === undefined) {
      await db.accounts.put({
        email: accountEmail,
        historyId: '',
        aliases,
        sendAsAliases,
        installTs: now,
        sendAsRefreshedAt: now,
      })
    } else {
      await db.accounts.put({ ...existing, aliases, sendAsAliases, sendAsRefreshedAt: now })
    }
  })

  return { aliases, sendAsAliases }
}
