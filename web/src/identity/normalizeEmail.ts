// Port of esc-chatmail/Services/TextProcessing/EmailNormalizer.swift.
// The normalize() output feeds participant hashing, so it must match iOS
// byte-for-byte — see the parity vectors in participantSet.test.ts. The
// display-name rules (sanitizing and ranking) have no shared golden fixture,
// so normalizeEmail.test.ts ports EmailNormalizerTests' cases instead.

import { containsEncodedWord, decodeRfc2047 } from '@/mime/rfc2047Decoder'

/**
 * Swift `CharacterSet.whitespacesAndNewlines`: Unicode category Z (Zs, Zl,
 * Zp) plus U+0009–U+000D and U+0085. JS `String.prototype.trim` strips a
 * different set — it includes U+FEFF (which Swift keeps) and lacks U+0085
 * (which Swift strips) — and the trimmed bytes feed the participant hash.
 */
const SWIFT_WHITESPACE_AND_NEWLINES_EDGES = /^[\t\n\v\f\r\u0085\p{Z}]+|[\t\n\v\f\r\u0085\p{Z}]+$/gu

function trimSwiftWhitespaceAndNewlines(value: string): string {
  return value.replace(SWIFT_WHITESPACE_AND_NEWLINES_EDGES, '')
}

/**
 * Swift `lowercased()` maps each scalar on its own. JS `toLowerCase` applies
 * the context-sensitive Final_Sigma rule ('ΣΑΣ' → 'σας'), so the two differ
 * on a Greek word-final sigma; lowercasing per code point disables it.
 */
function lowercasePerCodePoint(value: string): string {
  return [...value].map((codePoint) => codePoint.toLowerCase()).join('')
}

/**
 * Canonical email normalization for identity hashing: trim + lowercase; for
 * gmail.com/googlemail.com additionally strip '.' from the local part,
 * truncate the local part at '+', and canonicalize the domain to gmail.com.
 *
 * The scalars themselves are preserved, never NFC-normalized: Swift hashes
 * the scalars it was given, and the golden corpus pins a decomposed address
 * hashing in its decomposed form (unicode_combining_scalar_sort). Swift
 * `String` equality is canonical equivalence all the same, so a `Set` there
 * holds one member for "é" and "e"+U+0301 while a JS `Set` holds two; that
 * belongs to the set construction in participantSet.ts, not to this function.
 */
export function normalizeEmail(raw: string): string {
  const trimmed = lowercasePerCodePoint(trimSwiftWhitespaceAndNewlines(raw))

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

const BRACKETED_EMAIL_SOURCE = '<((?:"(?:[^"\\\\]|\\\\.)*"|[^<>"])+@[^<>]+)>'
const ANGLE_ADDRESS_CONTENT_RE = /^(?:"(?:[^"\\]|\\.)*"|[^<>"])+@[^<>]+$/

type AddressScanMode = 'phrase' | 'quote' | 'comment' | 'angle' | 'angleQuote'

/**
 * Splits an address header into one token per mailbox, at every comma
 * outside a quoted string, a comment and an angle-addr (port of
 * EmailAddressListParser.addressTokens).
 *
 * Comments are skipped as RFC 5322 has them, nested and with backslash
 * escapes: a comma inside one does not end the mailbox. Splitting there made
 * the text before it a mailbox of its own, so `(<boss@corp.example>, x)
 * <x@attacker.example>` (one mailbox, whose address is x@attacker.example)
 * read as boss@corp.example first. A comment that never closes runs to the
 * end, as a quote that never closes always has. The delimiters are ASCII, so
 * reading UTF-16 code units here finds them where Swift's Unicode scalars do.
 */
export function addressTokens(headerValue: string): string[] {
  const tokens: string[] = []
  let current = ''
  let mode: AddressScanMode = 'phrase'
  let commentDepth = 0
  let previousWasEscape = false

  const push = (token: string) => {
    const trimmed = token.trim()
    if (trimmed.length > 0) {
      tokens.push(trimmed)
    }
  }

  for (let index = 0; index < headerValue.length; index++) {
    const character = headerValue.charAt(index)
    const isEscaped: boolean = previousWasEscape
    let splitsHere = false
    switch (mode) {
      case 'phrase':
        if (character === '"' && !isEscaped) {
          mode = 'quote'
        } else if (character === '(' && !isEscaped) {
          mode = 'comment'
          commentDepth = 1
        } else if (character === '<') {
          mode = 'angle'
        } else if (character === ',') {
          splitsHere = true
        }
        break
      case 'quote':
        if (character === '"' && !isEscaped) mode = 'phrase'
        break
      case 'comment':
        if (character === '(' && !isEscaped) {
          commentDepth += 1
        } else if (character === ')' && !isEscaped) {
          commentDepth -= 1
          if (commentDepth === 0) mode = 'phrase'
        }
        break
      case 'angle':
        // Mailbox delimiters cannot nest: a nested '<' restarts the
        // angle-addr, so an unmatched display-name bracket cannot swallow
        // later recipients.
        if (character === '"' && !isEscaped) {
          mode = 'angleQuote'
        } else if (character === '>') {
          mode = 'phrase'
        }
        break
      case 'angleQuote':
        if (character === '"' && !isEscaped) mode = 'angle'
        break
    }

    if (splitsHere) {
      push(current)
      current = ''
    } else {
      current += character
    }
    previousWasEscape = character === '\\' && !isEscaped
  }

  push(current)
  return tokens
}

/** Where a mailbox's address sits in one address token. */
export interface MailboxAddressMatch {
  /** The address as written (not normalized). */
  email: string
  /** Index of the `<` that opens the angle-addr, or null for a bare address. */
  angleStart: number | null
}

/**
 * The address of the one mailbox in `token` (a value `addressTokens`
 * returned), in this order (port of EmailNormalizer.mailboxAddress(inToken:),
 * which it must match rule for rule):
 *
 * 1. the LAST complete `<…@…>` outside quoted strings and comments: a nested
 *    `<` restarts the angle-addr, so an unmatched bracket in a name never
 *    captures name text;
 * 2. else the first bare address outside quoted strings and comments;
 * 3. else the last `<…@…>` anywhere, quoted or not, which reads a token
 *    written wholly in quotes (`"John Doe <john@x.com>"`) and one whose quote
 *    or comment never closes. In the second case step 1 has already taken
 *    any address before the quote opened, so this is never the first of two
 *    addresses.
 *
 * A display name is the sender's: `"Boss <boss@corp.example>"
 * <x@attacker.example>` is one legal mailbox, x@attacker.example, and taking
 * the first `<…@…>` anywhere keyed it into Boss's chat as Boss's message.
 */
export function mailboxAddress(token: string): MailboxAddressMatch | null {
  let mode: AddressScanMode = 'phrase'
  let commentDepth = 0
  let previousWasEscape = false
  let angleStart = 0
  let lastComplete: MailboxAddressMatch | null = null
  // The token with every quoted string and comment blanked, for step 2.
  let phrase = ''

  for (let index = 0; index < token.length; index++) {
    const character = token.charAt(index)
    const isEscaped: boolean = previousWasEscape
    switch (mode) {
      case 'phrase':
        if (character === '"' && !isEscaped) {
          mode = 'quote'
          phrase += ' '
        } else if (character === '(' && !isEscaped) {
          mode = 'comment'
          commentDepth = 1
          phrase += ' '
        } else {
          phrase += character
          if (character === '<') {
            mode = 'angle'
            angleStart = index
          }
        }
        break
      case 'quote':
        phrase += ' '
        if (character === '"' && !isEscaped) mode = 'phrase'
        break
      case 'comment':
        phrase += ' '
        if (character === '(' && !isEscaped) {
          commentDepth += 1
        } else if (character === ')' && !isEscaped) {
          commentDepth -= 1
          if (commentDepth === 0) mode = 'phrase'
        }
        break
      case 'angle':
        phrase += character
        if (character === '"' && !isEscaped) {
          mode = 'angleQuote'
        } else if (character === '<') {
          angleStart = index
        } else if (character === '>') {
          const content = token.slice(angleStart + 1, index)
          if (content.includes('@') && ANGLE_ADDRESS_CONTENT_RE.test(content)) {
            lastComplete = { email: content, angleStart }
          }
          mode = 'phrase'
        }
        break
      case 'angleQuote':
        phrase += character
        if (character === '"' && !isEscaped) mode = 'angle'
        break
    }
    previousWasEscape = character === '\\' && !isEscaped
  }

  if (lastComplete !== null) return lastComplete

  const bare = firstBareEmailMatch(phrase)
  if (bare !== null) return { email: bare.email, angleStart: null }

  let lastBracketed: MailboxAddressMatch | null = null
  for (const match of token.matchAll(new RegExp(BRACKETED_EMAIL_SOURCE, 'g'))) {
    const email = match[1]
    if (email !== undefined) lastBracketed = { email, angleStart: match.index }
  }
  return lastBracketed
}

function firstMailbox(value: string): { token: string; match: MailboxAddressMatch } | null {
  for (const token of addressTokens(value)) {
    const match = mailboxAddress(token)
    if (match !== null) return { token, match }
  }
  return null
}

/**
 * The address of the first mailbox in an address header value (a whole
 * From, To or Cc value, or one token of it): the value is split into
 * mailboxes by `addressTokens`, and the first mailbox's address is read by
 * `mailboxAddress`, which skips quoted strings and comments.
 */
export function extractEmail(value: string): string | null {
  return firstMailbox(value)?.match.email ?? null
}

/**
 * The first address anywhere in free text, quoted or not: the leftmost
 * `<…@…>`, else the first bare address. This is what `extractEmail` was before
 * it learned quoted names, and it is right only for text that is not an
 * address header: `isEmailAddressShapedDisplayName` asks it whether a display
 * name embeds an address, which is the reading that hides `Boss
 * <boss@corp.example>` and `Acme (support@acme.com)` as names. Never use it on
 * a header value.
 */
function firstAddressAnywhere(value: string): string | null {
  const angledEmail = new RegExp(BRACKETED_EMAIL_SOURCE).exec(value)?.[1]
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
 * The display name of the first mailbox in an address header value: the text
 * before the `<` that `extractEmail` read the address from, so an address
 * inside a quoted name stays in the name (where
 * `isEmailAddressShapedDisplayName` hides it) and never becomes the mailbox's
 * address. Returns null when no usable name is present.
 */
export function extractDisplayName(value: string): string | null {
  const mailbox = firstMailbox(value)
  if (mailbox === null) return displayNameWithoutAngleAddress(value)
  return displayNameInToken(mailbox.token, mailbox.match)
}

/** The display name of the mailbox `match` read from `token`. */
export function displayNameInToken(token: string, match: MailboxAddressMatch): string | null {
  if (match.angleStart === null) return displayNameWithoutAngleAddress(token)
  const name = sanitizeDisplayName(token.slice(0, match.angleStart))
  return name === '' ? null : name
}

/**
 * The name of a value whose address is bare (`a@b (Name)`, `Name a@b`) or
 * missing, as `extractDisplayName` read every value before it learned quoted
 * names.
 */
function displayNameWithoutAngleAddress(value: string): string | null {
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
  if (firstAddressAnywhere(candidate) !== null) return true
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
