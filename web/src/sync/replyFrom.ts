// Reply-from resolution: which of the user's aliases a message was delivered
// to, and which alias a reply should be sent from. Port of
// ReplyFromAddressResolver / ReplyFromAddressSelector / EmailAddressListParser
// from Services/Send/SendAsAlias.swift.
//
// Resolution runs at sync time; the result is stored on the message row
// (deliveredToAddress / replyFromAddress). Selection runs at compose time and
// throws SendAsAliasUnavailableError when the delivered-to alias is no longer
// sendable — except for Gmail dot/plus-equivalent addresses, which fall back
// to the canonical alias instead of failing.

import type { SendAsAlias } from '@/db/types'
import { extractEmail, isGmailAddress, normalizeEmail } from '@/identity/normalizeEmail'
import { addressTokens } from '@/mime/address'
import { deduplicated, defaultAlias, normalizedAliasAddress } from './aliases'

/**
 * All normalized addresses in a recipient header value, in order
 * (EmailAddressListParser.emailAddresses).
 */
export function emailAddressesInHeader(headerValue: string): string[] {
  const addresses: string[] = []
  for (const token of addressTokens(headerValue)) {
    const email = extractEmail(token)
    if (email === null) continue
    const normalized = normalizedAliasAddress(email)
    if (normalized !== '') addresses.push(normalized)
  }
  return addresses
}

/**
 * Raw header values relevant to reply-from resolution. Multi-instance headers
 * (Delivered-To in particular) pass one entry per header occurrence, in
 * original header order; each value may itself contain an address list.
 */
export interface ReplyFromHeaders {
  /** True when the message carries the SENT label (the user's own mail). */
  isSent: boolean
  from?: string
  to?: readonly string[]
  cc?: readonly string[]
  xOriginalTo?: readonly string[]
  envelopeTo?: readonly string[]
  deliveredTo?: readonly string[]
}

export interface ReplyFromResolution {
  deliveredToAddress: string | null
  replyFromAddress: string | null
}

function candidatesFrom(headerValues: readonly string[] | undefined): string[] {
  if (headerValues === undefined) return []
  return headerValues.flatMap((value) => emailAddressesInHeader(value))
}

function firstMatchingAlias(
  candidates: readonly string[],
  aliases: readonly SendAsAlias[],
): SendAsAlias | null {
  for (const candidate of candidates) {
    const normalizedCandidate = normalizedAliasAddress(candidate)
    const alias = aliases.find((a) => normalizedAliasAddress(a.email) === normalizedCandidate)
    if (alias !== undefined) return alias
  }
  return null
}

/**
 * The 6-step resolution ladder (ReplyFromAddressResolver.resolve):
 * 1. SENT messages: the From alias, when it is one of ours.
 * 2. A non-default alias among To/Cc.
 * 3. An alias among X-Original-To, then Envelope-To, then Delivered-To.
 * 4. Any alias (including the default) among To/Cc.
 * 5. An unrecognized forwarding candidate: delivered-to is that address,
 *    reply-from falls back to the default alias.
 * 6. Fallback: the default alias for both (null when no aliases exist).
 */
export function resolveReplyFrom(
  headers: ReplyFromHeaders,
  sendAsAliases: readonly SendAsAlias[],
): ReplyFromResolution {
  const validAliases = deduplicated(sendAsAliases)
  const fallbackDefault = defaultAlias(validAliases)

  const directRecipientCandidates = [...candidatesFrom(headers.to), ...candidatesFrom(headers.cc)]

  // Step 1: sent-message From alias.
  if (headers.isSent) {
    const fromCandidates = headers.from === undefined ? [] : emailAddressesInHeader(headers.from)
    const senderAlias = firstMatchingAlias(fromCandidates, validAliases)
    if (senderAlias !== null) {
      return { deliveredToAddress: senderAlias.email, replyFromAddress: senderAlias.email }
    }
  }

  // Step 2: non-default alias among direct recipients.
  const nonDefaultAliases = validAliases.filter((alias) => !alias.isDefault)
  const nonDefaultMatch = firstMatchingAlias(directRecipientCandidates, nonDefaultAliases)
  if (nonDefaultMatch !== null) {
    return { deliveredToAddress: nonDefaultMatch.email, replyFromAddress: nonDefaultMatch.email }
  }

  // Step 3: forwarding headers, in fixed priority order.
  let firstForwardingCandidate: string | null = null
  for (const headerValues of [headers.xOriginalTo, headers.envelopeTo, headers.deliveredTo]) {
    const candidates = candidatesFrom(headerValues)
    if (firstForwardingCandidate === null && candidates.length > 0) {
      firstForwardingCandidate = candidates[0] ?? null
    }

    const forwardingMatch = firstMatchingAlias(candidates, validAliases)
    if (forwardingMatch !== null) {
      return { deliveredToAddress: forwardingMatch.email, replyFromAddress: forwardingMatch.email }
    }
  }

  // Step 4: any alias among direct recipients.
  const directMatch = firstMatchingAlias(directRecipientCandidates, validAliases)
  if (directMatch !== null) {
    return { deliveredToAddress: directMatch.email, replyFromAddress: directMatch.email }
  }

  // Step 5: unrecognized forwarding candidate.
  if (firstForwardingCandidate !== null) {
    return {
      deliveredToAddress: firstForwardingCandidate,
      replyFromAddress: fallbackDefault?.email ?? null,
    }
  }

  // Step 6: default alias for both.
  return {
    deliveredToAddress: fallbackDefault?.email ?? null,
    replyFromAddress: fallbackDefault?.email ?? null,
  }
}

/** Compose must surface this: the delivered-to alias can no longer send. */
export class SendAsAliasUnavailableError extends Error {
  readonly address: string

  constructor(address: string) {
    super(`Send-as alias unavailable: ${address}`)
    this.name = 'SendAsAliasUnavailableError'
    this.address = address
  }
}

/**
 * Gmail dot/plus equivalence: both sides are Gmail addresses and their fully
 * canonicalized forms match (user+tag@gmail.com ~ u.ser@gmail.com).
 */
export function matchesGmailEquivalent(lhs: string, rhs: string): boolean {
  const normalizedLhs = normalizedAliasAddress(lhs)
  const normalizedRhs = normalizedAliasAddress(rhs)
  if (!isGmailAddress(normalizedLhs) || !isGmailAddress(normalizedRhs)) return false
  return normalizeEmail(normalizedLhs) === normalizeEmail(normalizedRhs)
}

function matchingAlias(address: string, aliases: readonly SendAsAlias[]): SendAsAlias | null {
  const normalized = normalizedAliasAddress(address)
  return aliases.find((alias) => normalizedAliasAddress(alias.email) === normalized) ?? null
}

function matchingGmailEquivalentAlias(
  address: string,
  aliases: readonly SendAsAlias[],
): SendAsAlias | null {
  return aliases.find((alias) => matchesGmailEquivalent(address, alias.email)) ?? null
}

export interface SelectReplyFromOptions {
  /** Account email used when the alias list is empty (last-resort identity). */
  fallbackEmail?: string
  fallbackDisplayName?: string
}

/**
 * Picks the send-from alias for a reply (ReplyFromAddressSelector.select).
 * Throws SendAsAliasUnavailableError when the message was delivered to an
 * address that no configured alias (or the fallback email) covers — unless a
 * Gmail dot/plus-equivalent alias exists, in which case selection proceeds
 * and falls back to the exact replyFromAddress match or the default alias.
 */
export function selectReplyFromAlias(
  replyFromAddress: string | null,
  deliveredToAddress: string | null,
  sendAsAliases: readonly SendAsAlias[],
  options: SelectReplyFromOptions = {},
): SendAsAlias {
  const validAliases = deduplicated(sendAsAliases)
  const { fallbackEmail, fallbackDisplayName } = options

  const matchesFallback = (address: string): boolean => {
    if (fallbackEmail === undefined) return false
    return (
      normalizedAliasAddress(address) === normalizedAliasAddress(fallbackEmail) ||
      matchesGmailEquivalent(address, fallbackEmail)
    )
  }

  if (
    deliveredToAddress !== null &&
    deliveredToAddress.trim() !== '' &&
    matchingAlias(deliveredToAddress, validAliases) === null &&
    matchingGmailEquivalentAlias(deliveredToAddress, validAliases) === null &&
    !matchesFallback(deliveredToAddress)
  ) {
    throw new SendAsAliasUnavailableError(normalizedAliasAddress(deliveredToAddress))
  }

  if (replyFromAddress !== null) {
    const alias = matchingAlias(replyFromAddress, validAliases)
    if (alias !== null) return alias
  }

  const fallbackDefaultAlias = defaultAlias(validAliases)
  if (fallbackDefaultAlias !== null) return fallbackDefaultAlias

  if (fallbackEmail === undefined || fallbackEmail.trim() === '') {
    throw new Error('No send-as alias available and no fallback account email')
  }

  return {
    email: normalizedAliasAddress(fallbackEmail),
    displayName: fallbackDisplayName?.trim() ?? '',
    isDefault: true,
    isPrimary: true,
    verificationStatus: 'accepted',
  }
}
