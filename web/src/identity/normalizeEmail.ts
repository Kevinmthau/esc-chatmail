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

const BRACKETED_EMAIL_SOURCE = '<((?:"(?:[^"\\\\]|\\\\[\\s\\S])*"|[^<>"])+@[^<>]+)>'
// A quoted-pair is `\\[\s\S]`, as in the Swift pattern, whose ICU `.` leaves
// out U+000B, U+000C and U+0085.
const ANGLE_ADDRESS_CONTENT_RE = /^(?:"(?:[^"\\]|\\[\s\S])*"|[^<>"])+@[^<>]+$/
/**
 * What blanked text becomes in `scanMailbox`'s phrase: neither an address
 * character nor one the bare-address pattern takes as the end or start of an
 * address. A space ended one, so `me@corp.com(x).attacker.example`, whose
 * domain RFC 5322's obsolete syntax makes corp.com.attacker.example, read as
 * me@corp.com.
 */
const BLANK = '\u0001'

type AddressScanMode =
  | 'phrase'
  | 'quote'
  | 'comment'
  | 'angle'
  | 'angleQuote'
  | 'angleComment'
  | 'domainLiteral'
  | 'phraseLiteral'

/** One character of Swift's `CharacterSet.whitespacesAndNewlines`. */
const SWIFT_WHITESPACE_CHARACTER = /^[\t\n\v\f\r\u0085\p{Z}]$/u

/**
 * Splits an address header into one token per mailbox, at every comma
 * outside a quoted string, a comment and an angle-addr (port of
 * EmailAddressListParser.addressTokens, rule for rule).
 *
 * Comments are skipped as RFC 5322 has them, nested, in the phrase and inside
 * the angle-addr: a comma inside one does not end the mailbox. Splitting there
 * made the text before it a mailbox of its own, so `(<boss@corp.example>, x)
 * <x@attacker.example>` (one mailbox, whose address is x@attacker.example)
 * read as boss@corp.example first. Inside the angle-addr a domain literal
 * (`[…]`) and a quoted local part are text too. A backslash escapes only
 * inside a quoted string, a comment or a domain literal. A comment that never
 * closes runs to the end, as a quote that never closes always has. The
 * delimiters are ASCII, so reading UTF-16 code units here finds them where
 * Swift's Unicode scalars do; tokens are trimmed of Swift's whitespace set.
 */
export function addressTokens(headerValue: string): string[] {
  return addressTokenRanges(headerValue).map(([start, end]) => headerValue.slice(start, end))
}

/**
 * Where each of `addressTokens`' tokens sits in `headerValue` as `[start,
 * end)`, trimmed of whitespace, empty tokens left out (port of
 * EmailAddressListParser.addressTokenRanges).
 */
export function addressTokenRanges(headerValue: string): Array<[number, number]> {
  const ranges: Array<[number, number]> = []
  let tokenStart = 0
  let mode: AddressScanMode = 'phrase'
  let commentDepth = 0
  let previousWasEscape = false
  // As in `scanMailbox`: a `[` right after an `@` in the phrase opens a bare
  // address's domain literal.
  let lastPhraseCharacter: string | null = null

  const push = (start: number, end: number) => {
    let lower = start
    let upper = end
    while (lower < upper && SWIFT_WHITESPACE_CHARACTER.test(headerValue.charAt(lower))) lower += 1
    while (lower < upper && SWIFT_WHITESPACE_CHARACTER.test(headerValue.charAt(upper - 1)))
      upper -= 1
    if (lower < upper) ranges.push([lower, upper])
  }

  for (let index = 0; index < headerValue.length; index++) {
    const character = headerValue.charAt(index)
    const isEscaped: boolean = previousWasEscape
    let escapes = false
    let splitsHere = false
    switch (mode) {
      case 'phrase':
        if (character === '"') {
          mode = 'quote'
        } else if (character === '(') {
          mode = 'comment'
          commentDepth = 1
        } else if (character === '[' && lastPhraseCharacter === '@') {
          mode = 'phraseLiteral'
        } else if (character === '<') {
          mode = 'angle'
        } else if (character === ',') {
          splitsHere = true
          lastPhraseCharacter = null
        }
        if (
          !splitsHere &&
          (mode === 'phrase' || mode === 'angle') &&
          !SWIFT_WHITESPACE_CHARACTER.test(character)
        ) {
          lastPhraseCharacter = character
        }
        break
      case 'quote':
        escapes = true
        if (character === '"' && !isEscaped) mode = 'phrase'
        break
      case 'comment':
      case 'angleComment':
        escapes = true
        if (character === '(' && !isEscaped) {
          commentDepth += 1
        } else if (character === ')' && !isEscaped) {
          commentDepth -= 1
          if (commentDepth === 0) mode = mode === 'comment' ? 'phrase' : 'angle'
        }
        break
      case 'angle':
        // Mailbox delimiters cannot nest: a nested '<' restarts the
        // angle-addr, so an unmatched display-name bracket cannot swallow
        // later recipients.
        if (character === '"') {
          mode = 'angleQuote'
        } else if (character === '(') {
          mode = 'angleComment'
          commentDepth = 1
        } else if (character === '[') {
          mode = 'domainLiteral'
        } else if (character === '>') {
          mode = 'phrase'
        }
        break
      case 'angleQuote':
        escapes = true
        if (character === '"' && !isEscaped) mode = 'angle'
        break
      case 'domainLiteral':
        escapes = true
        if (character === ']' && !isEscaped) mode = 'angle'
        break
      case 'phraseLiteral':
        escapes = true
        if (character === ']' && !isEscaped) mode = 'phrase'
        break
    }

    if (splitsHere) {
      push(tokenStart, index)
      tokenStart = index + 1
    }
    previousWasEscape = escapes && character === '\\' && !isEscaped
  }

  push(tokenStart, headerValue.length)
  return ranges
}

/** Where a mailbox's address sits in one address token. */
export interface MailboxAddressMatch {
  /** The address as written (not normalized). */
  email: string
  /** Index of the `<` that opens the angle-addr, or null for a bare address. */
  angleStart: number | null
}

/**
 * What `scanMailbox` found in one token: an address; none at all;
 * `'ambiguous'` (two different addresses outside quoted strings and comments,
 * or an address in an angle-addr abandoned for a second `<`), where which one
 * is the mailbox's is the sender's choice, so neither is taken; or
 * `'unreadable'` (an `@` outside quoted strings and comments and no address
 * the scan can read: a quoted local part, a punycode TLD, a domain literal, an
 * obsolete-syntax domain that goes on past a comment or a space), which is
 * still the mailbox's address, so nothing else in the header may stand in for
 * it.
 */
type MailboxScan = MailboxAddressMatch | 'none' | 'ambiguous' | 'unreadable'

/**
 * The address of the one mailbox in `token` (a value `addressTokens`
 * returned), or null. `isOnlyMailbox` says the token is its header's only one,
 * which alone lets step 3 of `scanMailbox` read inside a quote or comment that
 * never closes.
 */
export function mailboxAddress(token: string, isOnlyMailbox: boolean): MailboxAddressMatch | null {
  const scan = scanMailbox(token, isOnlyMailbox)
  return typeof scan === 'string' ? null : scan
}

/**
 * Reads one token's mailbox (port of EmailNormalizer.scanMailbox, which it
 * must match rule for rule), in this order:
 *
 * 1. its complete `<…@…>` outside quoted strings and comments: a nested `<`
 *    restarts the angle-addr, so an unmatched bracket in a name (`Tom <3 Jerry
 *    <tom@x.com>`) never captures name text. Where two different ones are
 *    written, or the restart abandons a `<` that held an `@`, the token is
 *    ambiguous: taking the first or the last lets the sender pick, by order,
 *    which one the app reads (`<x@attacker.example> <me@gmail.com>` was the
 *    user's own mail);
 * 2. else the bare address outside quoted strings, comments, angle-addr
 *    comments and domain literals; ambiguous where two different ones are
 *    written, and unreadable where a `.` goes on from one of them past a space
 *    or a blanked comment (RFC 5322's obsolete syntax lets a domain or local
 *    part do that: `me@gmail.com.(x)attacker.example` is at
 *    gmail.com.attacker.example);
 * 3. else, only where the token is its header's only mailbox, a quote or
 *    comment never closes, and no `@` is outside quotes and comments, the last
 *    `<…@…>` anywhere. Its header's only mailbox: a token before it may be a
 *    real address the scan cannot read (`"x"@attacker.example,
 *    (<me@gmail.com>`). A token whose quotes and comments all close and that
 *    has no address outside them has none
 *    (`"<boss@corp.example>"`, `"John Doe <john@x.com>"`): read as an address,
 *    a quoted one became a mailbox of its own ahead of the real one
 *    (`"<boss@corp.example>", <x@attacker.example>`).
 *
 * RFC 5322's structure is followed where it decides which text is an address:
 * quoted strings; comments, which nest, in the phrase and inside the
 * angle-addr (`<x@attacker.example (><me@gmail.com>)>` is x@attacker.example,
 * and a comment there is left out of the address); domain literals, whose `<`
 * and `>` are text; a quoted local part inside the angle-addr. A backslash
 * escapes only inside a quoted string, a comment or a domain literal: read
 * anywhere, `x\"<me@gmail.com>" <x@attacker.example>` hid the quote that opens
 * the name.
 */
function scanMailbox(token: string, isOnlyMailbox: boolean): MailboxScan {
  let mode: AddressScanMode = 'phrase'
  let commentDepth = 0
  let previousWasEscape = false
  let angleStart = 0
  // The angle-addr's text, its comments left out.
  let angleContent = ''
  let angleHadComment = false
  let abandonedAngleHeldAddress = false
  const completes: MailboxAddressMatch[] = []
  // The token with every quoted string, comment and domain literal blanked,
  // and every complete angle-addr that is not an address, for step 2.
  const phrase: string[] = []
  let angleSegmentStart = 0
  // Whether the current angle-addr opened a quoted local part, a comment or a
  // domain literal.
  let angleOpenedStructure = false
  // The last character of the phrase that is not whitespace: a `[` right after
  // an `@` opens a bare address's domain literal, whose `@` and `,` are text
  // (`x@[me@gmail.com]` is one address, at that literal).
  let lastPhraseCharacter: string | null = null

  for (let index = 0; index < token.length; index++) {
    const character = token.charAt(index)
    const isEscaped: boolean = previousWasEscape
    let escapes = false
    switch (mode) {
      case 'phrase':
        if (character === '"') {
          mode = 'quote'
          phrase.push(BLANK)
        } else if (character === '(') {
          mode = 'comment'
          commentDepth = 1
          phrase.push(BLANK)
        } else if (character === '[' && lastPhraseCharacter === '@') {
          mode = 'phraseLiteral'
          phrase.push(BLANK)
        } else {
          if (!SWIFT_WHITESPACE_CHARACTER.test(character)) lastPhraseCharacter = character
          if (character === '<') {
            mode = 'angle'
            angleStart = index
            angleContent = ''
            angleHadComment = false
            angleOpenedStructure = false
            angleSegmentStart = phrase.length
          }
          phrase.push(character)
        }
        break
      case 'quote':
        escapes = true
        phrase.push(BLANK)
        if (character === '"' && !isEscaped) mode = 'phrase'
        break
      case 'comment':
        escapes = true
        phrase.push(BLANK)
        if (character === '(' && !isEscaped) {
          commentDepth += 1
        } else if (character === ')' && !isEscaped) {
          commentDepth -= 1
          if (commentDepth === 0) mode = 'phrase'
        }
        break
      case 'angle':
        if (character === '"') {
          mode = 'angleQuote'
          angleOpenedStructure = true
          angleContent += character
          phrase.push(BLANK)
        } else if (character === '(') {
          mode = 'angleComment'
          commentDepth = 1
          angleHadComment = true
          angleOpenedStructure = true
          phrase.push(BLANK)
        } else if (character === '[') {
          mode = 'domainLiteral'
          angleOpenedStructure = true
          angleContent += character
          phrase.push(BLANK)
        } else if (character === '<') {
          if (angleContent.includes('@')) abandonedAngleHeldAddress = true
          angleStart = index
          angleContent = ''
          angleHadComment = false
          angleOpenedStructure = false
          angleSegmentStart = phrase.length
          phrase.push(character)
        } else if (character === '>') {
          phrase.push(character)
          const content = angleHadComment
            ? trimSwiftWhitespaceAndNewlines(angleContent)
            : angleContent
          if (content.includes('@') && ANGLE_ADDRESS_CONTENT_RE.test(content)) {
            completes.push({ email: content, angleStart })
          } else {
            for (let position = angleSegmentStart; position < phrase.length; position++)
              phrase[position] = BLANK
          }
          mode = 'phrase'
        } else {
          angleContent += character
          phrase.push(character)
        }
        break
      case 'angleQuote':
        escapes = true
        angleContent += character
        phrase.push(BLANK)
        if (character === '"' && !isEscaped) mode = 'angle'
        break
      case 'angleComment':
        escapes = true
        phrase.push(BLANK)
        if (character === '(' && !isEscaped) {
          commentDepth += 1
        } else if (character === ')' && !isEscaped) {
          commentDepth -= 1
          if (commentDepth === 0) mode = 'angle'
        }
        break
      case 'domainLiteral':
        escapes = true
        angleContent += character
        phrase.push(BLANK)
        if (character === ']' && !isEscaped) mode = 'angle'
        break
      case 'phraseLiteral':
        escapes = true
        phrase.push(BLANK)
        if (character === ']' && !isEscaped) mode = 'phrase'
        break
    }
    previousWasEscape = escapes && character === '\\' && !isEscaped
  }

  // An address abandoned for a nested `<` is a second address, whatever
  // follows it.
  if (abandonedAngleHeldAddress) return 'ambiguous'
  const first = completes[0]
  if (first !== undefined) {
    const addresses = new Set(completes.map((complete) => normalizeEmail(complete.email)))
    if (addresses.size > 1) return 'ambiguous'
    return first
  }
  // An angle-addr that never closed after it opened a quoted local part, a
  // comment or a domain literal is not text for step 2: read there,
  // `<me@gmail.com"> <x@attacker.example>` was the user's own mail. One that
  // opened none (`Name <a@b.com`) still is.
  if (mode !== 'phrase' && mode !== 'quote' && mode !== 'comment' && angleOpenedStructure) {
    for (let position = angleSegmentStart; position < phrase.length; position++)
      phrase[position] = BLANK
  }

  const bare = bareAddress(phrase.join(''))
  if (bare !== 'none') return bare

  // Step 3 reads inside an unclosed quote or comment only where nothing
  // outside them has an `@`: a real address the bare-address pattern does not
  // know (`x@attacker.xn--p1ai (<me@gmail.com>`) is still the mailbox's, and
  // reading past it took the quoted one.
  const hasAddressSign = phrase.includes('@')
  if (!isOnlyMailbox || (mode !== 'quote' && mode !== 'comment') || hasAddressSign) {
    return hasAddressSign ? 'unreadable' : 'none'
  }
  let lastBracketed: MailboxAddressMatch | null = null
  for (const match of token.matchAll(new RegExp(BRACKETED_EMAIL_SOURCE, 'g'))) {
    const email = match[1]
    if (email !== undefined) lastBracketed = { email, angleStart: match.index }
  }
  return lastBracketed ?? 'none'
}

const BARE_EMAIL_GLOBAL_RE = new RegExp(BARE_EMAIL_RE.source, 'gi')
const BARE_ADDRESS_ENDERS = new Set([',', ';', '>', ')', ']'])

/**
 * Step 2 of `scanMailbox` (port of EmailNormalizer.bareAddress): the bare
 * address in `phrase`, where quoted strings, comments and literals are
 * `BLANK`. A match that a `.` goes on from, past whitespace or a blank, on
 * either side, is part of a longer address (RFC 5322's obsolete syntax lets
 * CFWS sit between the dots of a local part or a domain), so the token is
 * unreadable; a `.` that ends the text, or comes before `,`, `;`, `>`, `)` or
 * `]`, ends a sentence and not a domain.
 */
function bareAddress(phrase: string): MailboxScan {
  const isSpace = (character: string): boolean =>
    character === BLANK || SWIFT_WHITESPACE_CHARACTER.test(character)
  const found: string[] = []
  for (const match of phrase.matchAll(BARE_EMAIL_GLOBAL_RE)) {
    const email = match[1]
    if (email === undefined) continue
    const start = match.index + match[0].length - email.length
    const end = start + email.length
    let before = start
    while (before > 0 && isSpace(phrase.charAt(before - 1))) before -= 1
    if (before > 0 && phrase.charAt(before - 1) === '.') return 'unreadable'
    let after = end
    while (after < phrase.length && isSpace(phrase.charAt(after))) after += 1
    if (after < phrase.length && phrase.charAt(after) === '.') {
      let next = after + 1
      while (next < phrase.length && isSpace(phrase.charAt(next))) next += 1
      if (next < phrase.length && !BARE_ADDRESS_ENDERS.has(phrase.charAt(next))) return 'unreadable'
    }
    found.push(email)
  }
  const first = found[0]
  if (first === undefined) return 'none'
  if (new Set(found.map(normalizeEmail)).size > 1) return 'ambiguous'
  return { email: first, angleStart: null }
}

/**
 * The first mailbox of `value` that holds an address: the text from the first
 * token through the first token with an address, and that address (port of
 * EmailNormalizer.firstMailbox).
 *
 * Tokens before it hold no address at all (not even quoted), so they are a
 * name with a comma no one quoted: `The River Club of NY, Inc <…>` in a
 * forwarded message's From line, or an encoded word with a raw comma
 * (`=?utf-8?Q?Doe,Jane?= <…>`). They stay in the name. Joining them adds no
 * address: each starts in the phrase, where the comma left the scan, and none
 * has an address for the scan to take; where the joined text still reads
 * another address than the token alone, the token alone is taken. A first
 * mailbox that is ambiguous is no address at all, never a reason to read the
 * next one; nor is one that is unreadable: the next one was read in place of
 * a real address the scan could not (`"x"@attacker.example,
 * (<me@gmail.com>`). `parseEmailAddresses` reads each token alone, as the To
 * and Cc parser always has.
 */
function firstMailbox(value: string): { token: string; match: MailboxAddressMatch } | null {
  const ranges = addressTokenRanges(value)
  const isOnlyMailbox = ranges.length === 1
  let nameStart: number | null = null
  for (const [start, end] of ranges) {
    const token = value.slice(start, end)
    const scan = scanMailbox(token, isOnlyMailbox)
    if (scan === 'none') {
      nameStart ??= start
      continue
    }
    if (scan === 'ambiguous' || scan === 'unreadable') return null
    if (nameStart !== null) {
      const mailbox = value.slice(nameStart, end)
      const joined = scanMailbox(mailbox, false)
      if (
        typeof joined !== 'string' &&
        normalizeEmail(joined.email) === normalizeEmail(scan.email)
      ) {
        return { token: mailbox, match: joined }
      }
    }
    return { token, match: scan }
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
