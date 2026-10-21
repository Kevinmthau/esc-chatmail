// Port of esc-chatmail/Services/TextProcessing/EmailNormalizer.swift.
// The normalize() output feeds participant hashing, so it must match iOS
// byte-for-byte — see the parity vectors in participantSet.test.ts. The
// display-name rules (sanitizing and ranking) have no shared golden fixture,
// so normalizeEmail.test.ts ports EmailNormalizerTests' cases instead.

import { containsEncodedWord, decodeRfc2047 } from '@/mime/rfc2047Decoder'

/**
 * Canonical email normalization for identity hashing: trim + lowercase; for
 * gmail.com/googlemail.com additionally strip '.' from the local part,
 * truncate the local part at '+', and canonicalize the domain to gmail.com.
 */
export function normalizeEmail(raw: string): string {
  const trimmed = raw.trim().toLowerCase()

  const atIndex = trimmed.indexOf('@')
  if (atIndex === -1) return trimmed

  const localPart = trimmed.slice(0, atIndex)
  const domain = trimmed.slice(atIndex + 1)

  if (domain === 'gmail.com' || domain === 'googlemail.com') {
    let normalizedLocal = localPart.replaceAll('.', '')
    const plusIndex = normalizedLocal.indexOf('+')
    if (plusIndex !== -1) {
      normalizedLocal = normalizedLocal.slice(0, plusIndex)
    }
    return `${normalizedLocal}@gmail.com`
  }

  return trimmed
}

/** True if the email is a Gmail address (gmail.com or googlemail.com). */
export function isGmailAddress(email: string): boolean {
  const lowercased = email.toLowerCase()
  return lowercased.endsWith('@gmail.com') || lowercased.endsWith('@googlemail.com')
}

// RFC-ish bare-address matcher, ported from EmailNormalizer.firstBareEmailMatch.
const ATOM = "[A-Z0-9!#$%&'*+/=?^_`{|}~-]+"
const LOCAL_PART = `${ATOM}(?:\\.${ATOM})*`
const DOMAIN_LABEL = '[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?'
const DOMAIN = `${DOMAIN_LABEL}(?:\\.${DOMAIN_LABEL})*\\.[A-Z]{2,}`
const BARE_EMAIL_RE = new RegExp(
  `(?:^|[\\s<(\\[,;])(${LOCAL_PART}@${DOMAIN})(?=$|[\\s>)\\],;.!?])`,
  'i',
)

interface BareEmailMatch {
  email: string
  /** Start index of the address itself (not the delimiter prefix). */
  index: number
}

function firstBareEmailMatch(value: string): BareEmailMatch | null {
  const match = BARE_EMAIL_RE.exec(value)
  const email = match?.[1]
  if (!match || email === undefined) return null
  // match[0] is an optional one-char delimiter prefix plus the address.
  return { email, index: match.index + match[0].length - email.length }
}

/** Extracts the address from a header value: prefers `<...>`, falls back to a bare address. */
export function extractEmail(value: string): string | null {
  // Quoted local parts can contain brackets and escaped quotes. Consume
  // them as a unit, but never capture an unquoted nested '<' from a name.
  const angled = /<((?:"(?:[^"\\]|\\.)*"|[^<>"])+@[^<>]+)>/.exec(value)
  const angledEmail = angled?.[1]
  if (angledEmail !== undefined) return angledEmail

  return firstBareEmailMatch(value)?.email ?? null
}

/** Extracts every address from a comma-separated recipient header value. */
export function extractAllEmails(value: string): string[] {
  const emails: string[] = []
  for (const recipient of value.split(',')) {
    const email = extractEmail(recipient.trim())
    if (email !== null) emails.push(email)
  }
  return emails
}

/**
 * Extracts a display name from `"Name" <a@b>`, `a@b (Name)`, or `Name a@b`
 * header shapes. Returns null when no usable name is present.
 */
export function extractDisplayName(value: string): string | null {
  const emailStartIndex = value.indexOf('<')
  if (emailStartIndex !== -1) {
    const name = sanitizeDisplayName(value.slice(0, emailStartIndex))
    return name === '' ? null : name
  }

  const trimmed = value.trim()
  const commentStart = trimmed.lastIndexOf('(')
  if (commentStart !== -1 && trimmed.endsWith(')')) {
    const beforeComment = firstBareEmailMatch(trimmed.slice(0, commentStart))
    if (beforeComment !== null && beforeComment.email !== '') {
      const comment = sanitizeDisplayName(trimmed.slice(commentStart + 1, trimmed.length - 1))
      return comment === '' ? null : comment
    }
  }

  const bareMatch = firstBareEmailMatch(trimmed)
  if (bareMatch !== null) {
    const leadingName = sanitizeDisplayName(trimmed.slice(0, bareMatch.index))
    return leadingName === '' ? null : leadingName
  }

  return null
}

/**
 * Decodes RFC 2047 encoded-words and strips quoting from a display-name
 * phrase parsed out of an address header. Decoding happens AFTER the address
 * structure is parsed so decoded content can never inject a fake "<addr>"
 * into address parsing, and BEFORE quote-stripping so a name that only
 * becomes quoted once decoded is still unquoted for display.
 *
 * Quote-stripping removes every double quote, then peels the wrapping quotes
 * `stripWrappingQuotes` recognizes. Outlook and Exchange write a recipient as
 * `'Jacob Laycock' <…>` or `"'Jacob Laycock'" <…>`; removing only double
 * quotes stored and showed `'Jacob Laycock'`, and because the quotes hid that
 * it restates jacob.laycock@'s address, it outranked the plain "Jacob Laycock"
 * in `isBetterDisplayNameForEmail`. A quote inside a name (`O'Brien`, `'Til
 * Tuesday`) is not wrapping and stays. The pairs are not matched, so a name
 * that merely starts and ends with a quoted part (`'Ann' & 'Bob'`) loses its
 * outer two quotes; such header names are rare enough not to justify parsing
 * quote nesting.
 *
 * Exported for the stored-name repair (sync/displayNameRepair.ts), which
 * rewrites a name stored with raw encoded-words to what this now stores.
 */
export function sanitizeDisplayName(name: string): string {
  return stripWrappingQuotes(decodeRfc2047(name).replaceAll('"', ''))
}

/**
 * Converts an email local part to a formatted display name,
 * e.g. "firstname.lastname" -> "Firstname Lastname".
 */
export function formatAsDisplayName(email: string): string {
  const trimmed = email.trim()
  const atIndex = trimmed.indexOf('@')
  const username = atIndex === -1 ? trimmed : trimmed.slice(0, atIndex)

  return username
    .replaceAll('.', ' ')
    .replaceAll('_', ' ')
    .replaceAll('-', ' ')
    .split(' ')
    .filter((part) => part !== '')
    .map((part) => part.slice(0, 1).toUpperCase() + part.slice(1).toLowerCase())
    .join(' ')
}

/**
 * True if `newName` is "better" than `existingName`: more name parts, or the
 * same number of parts but longer.
 */
export function isBetterDisplayName(
  newName: string | null | undefined,
  existingName: string | null | undefined,
): boolean {
  if (newName === null || newName === undefined || newName === '') return false
  if (existingName === null || existingName === undefined || existingName === '') return true

  const newParts = newName.split(' ').filter((part) => part !== '')
  const existingParts = existingName.split(' ').filter((part) => part !== '')

  if (newParts.length > existingParts.length) return true
  if (newParts.length < existingParts.length) return false

  return newName.length > existingName.length
}

/**
 * True if `newName` should replace `existingName` for a specific email.
 * Address-derived names are weak: they were likely synthesized from the local
 * part before a real header or contact name was available.
 *
 * Never true in both directions for one pair, or the stored name would flip
 * with every header that carries the other one (normalizeEmail.test.ts checks
 * this over a table of realistic pairs). It can be false in both directions:
 * such a tie keeps whichever name is already stored.
 */
export function isBetterDisplayNameForEmail(
  newName: string | null | undefined,
  existingName: string | null | undefined,
  email: string,
): boolean {
  const quotedNew = newName?.trim()
  if (quotedNew === undefined || quotedNew === '') return false
  const quotedExisting = existingName?.trim()
  if (quotedExisting === undefined || quotedExisting === '') return true

  // Rows stored before `sanitizeDisplayName` peeled Outlook's wrapping quotes
  // still hold `'Jacob Laycock'`. Rank every name as written inside its
  // quotes: the quotes hid that it restates jacob.laycock@'s address, so it
  // replaced the address-derived "Jacob Laycock" at an equal part count and
  // the plain name could never win back, and they made it the longer name in
  // the base ranking. A quoted name and its own unquoted form are one name,
  // and the shorter spelling (fewer quotes) wins, so ingestion heals a quoted
  // row when the name recurs.
  const unquotedNew = stripWrappingQuotes(quotedNew)
  const unquotedExisting = stripWrappingQuotes(quotedExisting)
  if (unquotedNew === '') return false
  if (unquotedExisting === '') return true
  if (unquotedNew === unquotedExisting) {
    return quotedNew.length < quotedExisting.length
  }

  // A name still carrying a raw RFC 2047 encoded-word is garbage on screen:
  // any decoded candidate beats it, and an undecoded candidate never
  // replaces a clean existing name.
  const existingLooksEncoded = containsEncodedWord(unquotedExisting)
  const newLooksEncoded = containsEncodedWord(unquotedNew)
  if (existingLooksEncoded !== newLooksEncoded) {
    return existingLooksEncoded
  }

  // An address used as a display name (a To/Cc header written as
  // `"jacob.laycock@studs.com" <jacob.laycock@studs.com>`) names no one: it
  // never replaces a name, and any name replaces it. Without this the address
  // split into more comparison parts than the address-derived "Jacob Laycock"
  // and won the branch below, while "Jacob Laycock" had more words than the
  // address and won it back, so the stored Person name flipped with header
  // order; an address that replaced a one-word name ("Jake") was longer than
  // any one-word name and never left.
  const existingIsAddress = isEmailAddressShapedDisplayName(unquotedExisting, email)
  const newIsAddress = isEmailAddressShapedDisplayName(unquotedNew, email)
  if (existingIsAddress !== newIsAddress) {
    return existingIsAddress
  }

  // Each branch below decides a pair the same way from both sides. A pair
  // that ranked better in both directions made the stored name follow header
  // order: for jacob.laycock@, the real "Jake Laycock" replaced the
  // address-derived "Jacob Laycock" at an equal part count, and "Jacob
  // Laycock" won it back as the longer name.
  const existingIsDerived = isAddressDerivedDisplayName(unquotedExisting, email)
  const newIsDerived = isAddressDerivedDisplayName(unquotedNew, email)
  if (existingIsDerived && !newIsDerived) {
    return displayNameParts(unquotedNew).length >= displayNameParts(unquotedExisting).length
  }

  if (newIsDerived && !existingIsDerived) {
    // The converse of the branch above: a derived name replaces a real one
    // only with strictly more parts (a fuller "John Doe" over "John"), never
    // at an equal part count, where the real name wins.
    if (displayNameParts(unquotedNew).length <= displayNameParts(unquotedExisting).length) {
      return false
    }
    return isBetterDisplayName(unquotedNew, unquotedExisting)
  }

  if (newIsDerived && existingIsDerived) {
    // Intentional casing ("BONBONWHIMS") beats the auto-formatted
    // "Bonbonwhims" whatever their word counts. Two intentionally cased
    // variants fall through to the base ranking rather than each replacing
    // the other; a case-only pair is a tie that keeps the stored name.
    const newHasIntentionalCasing = hasIntentionalCasing(unquotedNew)
    if (newHasIntentionalCasing !== hasIntentionalCasing(unquotedExisting)) {
      return newHasIntentionalCasing
    }
  }

  return isBetterDisplayName(unquotedNew, unquotedExisting)
}

/**
 * True when a display name is, or embeds, an email address rather than a
 * name. Only an address the bare-address pattern matches counts — a dotted
 * domain ending in an ASCII label of two or more letters — unless `email` is
 * given: then the name, less its wrapping quotes, being `email` itself also
 * counts. Header extraction takes any address inside angle brackets, so a
 * header that repeats a dotless, internationalized or domain-literal address
 * (`"ops@intranet" <ops@intranet>`) yields a name the bare pattern does not
 * match; comparing with the participant's own address still catches it.
 * `isBetterDisplayNameForEmail` never lets such a name replace a name.
 *
 * Outlook and Exchange write a recipient that has no name as
 * `"'jacob.laycock@studs.com'" <jacob.laycock@studs.com>`, and the bare
 * pattern rejects the trailing `'`. `sanitizeDisplayName` peels those quotes,
 * but names stored before it did still hold `'addr'`, so wrapping quotes are
 * peeled before matching.
 */
export function isEmailAddressShapedDisplayName(displayName: string, email?: string): boolean {
  const candidate = stripWrappingQuotes(displayName)
  if (!candidate.includes('@')) return false
  if (extractEmail(candidate) !== null) return true
  return email !== undefined && normalizeEmail(candidate) === normalizeEmail(email)
}

const WRAPPING_QUOTE_PAIRS: ReadonlyArray<readonly [open: string, close: string]> = [
  ['"', '"'],
  ["'", "'"],
  ['\u201C', '\u201D'],
  ['\u2018', '\u2019'],
  ['\u00AB', '\u00BB'],
]

/**
 * The opening quote of each pair `stripWrappingQuotes` peels (port of
 * EmailNormalizer.wrappingQuoteOpeners). A string without any of them cannot
 * hold a quote-wrapped name, which lets the stored-name repair
 * (sync/displayNameRepair.ts) skip it.
 */
export const WRAPPING_QUOTE_OPENERS: readonly string[] = WRAPPING_QUOTE_PAIRS.map(([open]) => open)

/**
 * `value`, trimmed, with every layer of wrapping quotes ("…", '…', “…”, ‘…’,
 * «…») peeled off, as Outlook writes an address it repeats as the name
 * (`'ops@intranet'`) or quotes a name; anything else is only trimmed. Shared
 * with `sanitizeDisplayName` and the ranking in `isBetterDisplayNameForEmail`
 * (port of EmailNormalizer.strippingWrappingQuotes), so they agree on what
 * counts as quoting.
 */
export function stripWrappingQuotes(value: string): string {
  let result = value.trim()
  let didStrip = true
  while (didStrip && result.length >= 2) {
    didStrip = false
    for (const [open, close] of WRAPPING_QUOTE_PAIRS) {
      if (result.startsWith(open) && result.endsWith(close)) {
        result = result.slice(1, -1).trim()
        didStrip = true
        break
      }
    }
  }
  return result
}

/** True when the display name is just a re-formatting of the address itself. */
export function isAddressDerivedDisplayName(
  displayName: string | null | undefined,
  email: string,
): boolean {
  const trimmedName = displayName?.trim()
  if (trimmedName === undefined || trimmedName === '') return false

  const trimmedEmail = email.trim()
  const atIndex = trimmedEmail.indexOf('@')
  const localPart = atIndex === -1 ? trimmedEmail : trimmedEmail.slice(0, atIndex)

  const comparable = displayNameForComparison(trimmedName)
  return (
    comparable === displayNameForComparison(localPart) ||
    comparable === displayNameForComparison(formatAsDisplayName(email))
  )
}

/**
 * True for Apple's "Hide My Email" placeholder contact labels. These represent
 * relay routing aliases rather than real participants and are excluded from
 * conversation identity and display.
 */
export function isHideMyEmailDisplayName(displayName: string | null | undefined): boolean {
  if (displayName === null || displayName === undefined) return false
  const normalized = displayName
    .trim()
    .toLowerCase()
    .replaceAll('-', ' ')
    .replaceAll('_', ' ')
    .replace(/\s+/g, ' ')
  return normalized === 'hide my email'
}

function displayNameForComparison(value: string): string {
  return value
    .trim()
    .replaceAll('"', '')
    .replaceAll('.', ' ')
    .replaceAll('_', ' ')
    .replaceAll('-', ' ')
    .replace(/\s+/g, ' ')
    .toLowerCase()
}

function displayNameParts(value: string): string[] {
  return displayNameForComparison(value)
    .split(' ')
    .filter((part) => part !== '')
}

function hasIntentionalCasing(value: string): boolean {
  // Swift filters with Character.isLetter, which keeps caseless-script
  // letters (CJK, kana, ...) in the count; \p{L} is the code-point
  // equivalent. Filtering by "has distinct case forms" instead would drop
  // them and diverge (e.g. "汉字X" must count three letters, not one).
  const letters = [...value].filter((ch) => /\p{L}/u.test(ch))
  if (letters.length <= 1) return false

  // Swift Character.isUppercase is false for caseless letters, so the cased
  // check (`ch !== ch.toLowerCase()`) must guard BOTH branches — a bare
  // `ch === ch.toUpperCase()` would treat every caseless letter as uppercase.
  const isUppercase = (ch: string): boolean => ch === ch.toUpperCase() && ch !== ch.toLowerCase()

  if (letters.every(isUppercase)) return true

  return letters.slice(1).some(isUppercase)
}
