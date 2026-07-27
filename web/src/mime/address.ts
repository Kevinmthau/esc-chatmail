// Header email/display-name extraction for MIME parsing.
//
// The extraction and normalization helpers are owned by the identity module
// (src/identity/normalizeEmail.ts, the EmailNormalizer.swift port) and
// re-exported here so both modules share one implementation. Note that
// normalizeEmail performs full canonicalization (trim + lowercase, plus
// Gmail dot-strip / plus-truncation / googlemail→gmail), matching iOS
// MessageProcessor.parseEmailAddresses which stores canonicalized addresses
// on parsed recipient rows.
export { extractDisplayName, extractEmail, normalizeEmail } from '../identity/normalizeEmail'

/**
 * Splits a recipient header into per-address tokens, respecting quoted
 * strings and angle brackets (port of EmailAddressListParser.addressTokens).
 */
export function addressTokens(headerValue: string): string[] {
  const tokens: string[] = []
  let current = ''
  let isInQuotes = false
  let angleDepth = 0
  let previousWasEscape = false

  const push = (token: string) => {
    const trimmed = token.trim()
    if (trimmed.length > 0) {
      tokens.push(trimmed)
    }
  }

  for (const character of headerValue) {
    if (character === '"' && !previousWasEscape) {
      isInQuotes = !isInQuotes
      current += character
    } else if (character === '<' && !isInQuotes) {
      angleDepth += 1
      current += character
    } else if (character === '>' && !isInQuotes) {
      angleDepth = Math.max(0, angleDepth - 1)
      current += character
    } else if (character === ',' && !isInQuotes && angleDepth === 0) {
      push(current)
      current = ''
    } else {
      current += character
    }

    previousWasEscape = character === '\\' && !previousWasEscape
  }

  push(current)
  return tokens
}
