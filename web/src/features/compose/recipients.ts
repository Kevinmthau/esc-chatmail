// Recipient-chip model for the compose dialog (port of the chip rules in
// iOS RecipientInputSection). Pure functions so commit/dedupe/validation are
// unit-testable without the DOM.

import { normalizeEmail } from '@/identity/normalizeEmail'
import { newId } from '@/lib/uuid'
import { isSingleAddrSpec } from '@/outbox/mimeBuilder'

/** Domain must look routable (something@something.tld) — iOS compose validation. */
const DOMAIN_HAS_TLD = /\.[^.\s]+$/u

/** Separators that always end a chip: ',' plus ';' for Outlook-style pastes. */
const CHIP_SEPARATORS = /[,;]/u

export interface RecipientChipData {
  /** Stable local id for list rendering/removal. */
  id: string
  /** Trimmed raw text the user committed — exactly what gets sent. */
  email: string
  /** Canonical form (identity/normalizeEmail) used for dedupe. */
  normalized: string
  /** Invalid chips render in the danger tint and block the send until fixed or removed. */
  valid: boolean
}

/**
 * A chip counts as sendable only when the MIME builder will also accept it
 * (isSingleAddrSpec) — a chip the UI calls valid but the builder refuses would
 * either narrow the send silently or fail it at the last moment. That rejects
 * multi-address pastes ('a@b.com;c@d.com'), name-addr text ('Bob <b@x.com>')
 * and anything carrying separators/quotes.
 */
export function isValidRecipient(raw: string): boolean {
  const address = raw.trim()
  if (!isSingleAddrSpec(address)) return false
  return DOMAIN_HAS_TLD.test(address.slice(address.indexOf('@') + 1))
}

/** True when the input carries a separator that should commit a chip. */
export function hasChipSeparator(value: string): boolean {
  return CHIP_SEPARATORS.test(value)
}

/** Splits raw input on ',' / ';'; the last element is the uncommitted remainder. */
export function splitOnChipSeparators(value: string): string[] {
  return value.split(CHIP_SEPARATORS)
}

/**
 * Expands one committed segment into the addresses it actually contains.
 * Whitespace separates ONLY when every resulting token is a valid address, so
 * a space-joined paste ('a@b.com c@d.com') becomes two chips while a name
 * typed for autocomplete ('john sm') is never chopped up.
 */
export function splitRecipientSegment(raw: string): string[] {
  const trimmed = raw.trim()
  if (trimmed === '') return []
  const tokens = trimmed.split(/\s+/u)
  if (tokens.length > 1 && tokens.every((token) => isValidRecipient(token))) return tokens
  return [trimmed]
}

/** Builds a chip from raw input; null when the trimmed text is empty. */
export function makeChip(raw: string): RecipientChipData | null {
  const email = raw.trim()
  if (email === '') return null
  const normalized = normalizeEmail(email)
  return {
    // newId(), not crypto.randomUUID: the latter is secure-context-only.
    id: newId(),
    email,
    normalized: normalized === '' ? email.toLowerCase() : normalized,
    valid: isValidRecipient(email),
  }
}

export interface AddChipResult {
  next: RecipientChipData[]
  /** The chip that was added, or null (empty input or duplicate). */
  added: RecipientChipData | null
  duplicate: boolean
}

/** Commits raw text as a chip, deduping by normalized address. */
export function addChip(chips: readonly RecipientChipData[], raw: string): AddChipResult {
  const chip = makeChip(raw)
  if (chip === null) return { next: [...chips], added: null, duplicate: false }
  if (chips.some((existing) => existing.normalized === chip.normalized)) {
    return { next: [...chips], added: null, duplicate: true }
  }
  return { next: [...chips, chip], added: chip, duplicate: false }
}

/**
 * The valid chips' addresses, raw form: the dedup-to-existing-chat key, and
 * the send's recipient list once the send gate has proven every chip valid.
 */
export function validRecipientEmails(chips: readonly RecipientChipData[]): string[] {
  return chips.filter((chip) => chip.valid).map((chip) => chip.email)
}

/** The chips the send gate refuses; empty means every committed chip is sendable. */
export function invalidRecipientChips(chips: readonly RecipientChipData[]): RecipientChipData[] {
  return chips.filter((chip) => !chip.valid)
}

/**
 * Copy naming the chips that hold the send, in the same shape the MIME builder's
 * rejection takes (outbox/send: InvalidRecipientsError → userMessage), so an
 * address reads the same whether it is caught here or at the builder. Null
 * when nothing holds it.
 */
export function invalidRecipientMessage(chips: readonly RecipientChipData[]): string | null {
  const invalid = invalidRecipientChips(chips)
  if (invalid.length === 0) return null
  const list = invalid.map((chip) => chip.email).join(', ')
  return invalid.length === 1
    ? `${list} is not a valid email address.`
    : `These are not valid email addresses: ${list}.`
}

/** Option-element id used for aria-activedescendant on the combobox input. */
export function autocompleteOptionId(listId: string, index: number): string {
  return `${listId}-option-${index}`
}
