// Port of esc-chatmail/Services/TextProcessing/EmailNormalizer.swift.
// The normalize() output feeds participant hashing, so it must match iOS
// byte-for-byte — see the parity vectors in participantSet.test.ts.

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
    const name = value.slice(0, emailStartIndex).trim()
    return name === '' ? null : name.replaceAll('"', '')
  }

  const trimmed = value.trim()
  const commentStart = trimmed.lastIndexOf('(')
  if (commentStart !== -1 && trimmed.endsWith(')')) {
    const beforeComment = firstBareEmailMatch(trimmed.slice(0, commentStart))
    if (beforeComment !== null && beforeComment.email !== '') {
      const comment = trimmed
        .slice(commentStart + 1, trimmed.length - 1)
        .trim()
        .replaceAll('"', '')
      return comment === '' ? null : comment
    }
  }

  const bareMatch = firstBareEmailMatch(trimmed)
  if (bareMatch !== null) {
    const leadingName = trimmed.slice(0, bareMatch.index).trim().replaceAll('"', '')
    return leadingName === '' ? null : leadingName
  }

  return null
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
 */
export function isBetterDisplayNameForEmail(
  newName: string | null | undefined,
  existingName: string | null | undefined,
  email: string,
): boolean {
  const trimmedNew = newName?.trim()
  if (trimmedNew === undefined || trimmedNew === '') return false
  const trimmedExisting = existingName?.trim()
  if (trimmedExisting === undefined || trimmedExisting === '') return true

  if (isAddressDerivedDisplayName(trimmedExisting, email)) {
    if (!isAddressDerivedDisplayName(trimmedNew, email)) {
      return displayNameParts(trimmedNew).length >= displayNameParts(trimmedExisting).length
    }

    if (trimmedNew !== trimmedExisting && hasIntentionalCasing(trimmedNew)) {
      return true
    }
  }

  return isBetterDisplayName(trimmedNew, trimmedExisting)
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
