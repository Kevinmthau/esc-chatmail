// Plain-text signature/boilerplate removal.
// Port of esc-chatmail/Services/TextProcessing/PlainTextSignatureRemover.swift.

import {
  ADDRESS_KEYWORD_PATTERN,
  DESCRIPTIVE_PHONE_LINE_PATTERN,
  SIGN_OFF_PHRASES,
  shouldPreserveSignatureNameLine,
  isStrongSignatureSupportLine,
  EMAIL_ADDRESS_PATTERN,
  PHONE_PATTERN,
  SIGNATURE_DELIMITER_PATTERN,
  STANDALONE_CONTACT_LABEL_PATTERN,
  WEB_URL_PATTERN,
} from './patterns'
import {
  isContactSignatureLine,
  isSignatureSupportLine,
  isTrailingSignatureContactLine,
} from './html'
import { isListItem, normalizeLineEndings } from './text'

const TRAILING_SCAN_LINE_LIMIT = 80

interface LineEvaluation {
  isHardIndicator: boolean
  isLikelySignatureLine: boolean
  hasContactInfo: boolean
}

const HARD_INDICATOR_FRAGMENTS: string[] = [
  // Mobile signatures
  'sent from my iphone',
  'sent from my ipad',
  'sent from my android',
  'sent from outlook',
  'get outlook for',
  'download outlook',
  'sent from mail for windows',
  'sent from samsung',
  'sent from my galaxy',
  'sent from my pixel',
  'sent from spark',
  'sent from protonmail',
  'sent from bluemail',
  'sent from gmail',
  'sent from yahoo mail',
  'sent from my mobile',
  'sent from my phone',
  'sent via ',
  'sent using ',
  'get bluemail for',
  'sent from typeapp',

  // Unsubscribe and preference links
  'unsubscribe',
  'update your email preferences',
  'manage your subscription',
  'click here to unsubscribe',
  'opt out of future',
  'view this email in your browser',
  'having trouble viewing this email',
  'you are receiving this',
  'you received this email because',

  // Legal disclaimers
  'notice to recipient:',
  'this email and any attachments',
  'this message is intended',
  'this e-mail is meant for only the intended recipient',
  'this communication is confidential',
  'this communication is provided for informational purposes and is not an account statement',
  'our form crs and guide to investment services contain important information',
  'this message contains confidential',
  'this e-mail is confidential',
  'this electronic mail transmission may contain confidential',
  'the information in this email',
  'if you are not the intended recipient',
  'if you received this e-mail in error',
  'if you have received this email in error',
  'if you believe you have received this message in error',
  'for additional policies governing this e-mail',
  'confidentiality notice:',
  'disclaimer:',
  'legal disclaimer:',
  'please consider the environment',
  'think before you print',

  // Social / footer links
  'follow us on',
  'connect with us',
  'join us on',
  'find us on',
  'visit our website',
  'privacy policy',
  'terms of service',
  'copyright ©',
  '© 20',

  // Marketing boilerplate
  'forward to a friend',
  'share this email',
  'reply stop to unsubscribe',

  // Wire fraud warnings (real estate)
  '*wire fraud',
  'wire fraud is real',
  'before wiring any money',
]

// Legal openers only admit known disclaimer sentence forms in later paragraphs.
const LEGAL_CONTINUATION_PREFIXES = [
  'please refer to your monthly statements for the official record',
  'questions should be directed to your',
  'you should consult your own tax, legal, and accounting advisors',
  'please submit personal information through secure channels',
  'investment products involve risk',
  'no bank guarantee is provided for investment products',
  'this material is intended solely for the recipient',
  'distribution to unintended recipients is restricted',
  'any forwarding should comply with firm communication standards',
  'payment details should always be confirmed by phone using a known number',
  'if funds were sent to an unintended account',
  'additional disclosures may apply based on account type',
  'product availability depends on review and approval requirements',
  'services described may vary by location and client eligibility',
  'historical references do not guarantee future performance',
  'terms may be updated periodically without prior notice',
  'use of electronic communication is subject to monitoring and retention',
  'this message may include privileged information under applicable law',
]

const SIGN_OFF_WORDS = SIGN_OFF_PHRASES

const CONTACT_PREFIX_PATTERN =
  /^(?:[mcofdtp](?:\s*:\s*|\s+)|(?:tel|phone|mobile|office|direct|fax)(?:[.:]\s+|\s+))\(?\+?\d[\d\s().-]{5,}\b/i

const TITLE_KEYWORDS = [
  'director',
  'manager',
  'vp',
  'vice president',
  'president',
  'founder',
  'ceo',
  'cfo',
  'cto',
  'coo',
  'realtor',
  'broker',
  'associate',
  'sales',
  'agent',
  'partner',
  'principal',
  'owner',
]

const ORGANIZATION_KEYWORDS = [
  ' inc',
  ' inc.',
  ' llc',
  ' ltd',
  ' corp',
  ' corp.',
  ' corporation',
  ' company',
  ' co.',
  ' partners',
  ' group',
]

const SINGLE_NAME_PATTERN = /^[A-Z][A-Za-z'-]{1,31}$/
const MULTI_WORD_NAME_PATTERN = /^[A-Z][A-Za-z'.-]{1,31}(?:\s+[A-Z][A-Za-z'.-]{1,31}){1,3}$/

const CONTACT_LIST_INTRO_KEYWORDS = ['contact', 'email', 'reviewer', 'recipient']

/** Removes trailing signature blocks and boilerplate from plain text. */
export function removeSignature(text: string): string {
  const normalized = normalizeLineEndings(text)
  const trimmed = normalized.trim()
  if (trimmed.length === 0) return ''

  const lines = normalized.split('\n')
  if (lines.length <= 1) return trimmed

  let lastNonEmpty = lines.length - 1
  while (lastNonEmpty >= 0 && lines[lastNonEmpty]!.trim().length === 0) {
    lastNonEmpty -= 1
  }
  if (lastNonEmpty < 0) return ''

  if (preservesPostscriptAfterSignOff(lines, lastNonEmpty)) {
    return trimmed
  }

  const scanStart = Math.max(0, lastNonEmpty - TRAILING_SCAN_LINE_LIMIT)
  // Pass 1: definitive signature indicators near the end.
  let earliestHardIndicator: number | null = null
  for (let index = lastNonEmpty; index >= scanStart; index--) {
    const line = lines[index]!.trim()
    if (line.length === 0) continue

    const evaluation = evaluateLine(line)
    if (evaluation.isHardIndicator && hasSignatureOnlyTail(index, lines, lastNonEmpty)) {
      earliestHardIndicator = index
    }
  }
  if (earliestHardIndicator !== null) {
    const hardIndicatorLine = lines[earliestHardIndicator]!.trim()
    if (isDelimiterLine(hardIndicatorLine)) {
      return joinLines(lines, earliestHardIndicator)
    }
    const startLine = findSignatureStartLine(earliestHardIndicator, lines)
    return joinLines(lines, preservingSignOff(startLine, earliestHardIndicator, lines))
  }

  // A body sentence or bare sign-off after contact information ends the block.
  if (!evaluateLine(lines[lastNonEmpty]!).hasContactInfo) {
    // A clipped corporate row must expand the standalone name immediately above.
    const nameIndex = previousNonEmptyLineIndex(lastNonEmpty, lines)
    if (
      containsSignatureSeparator(lines[lastNonEmpty]!) &&
      nameIndex !== null &&
      shouldPreserveSingleNameSignOff(lines[nameIndex]!, nameIndex, lines)
    ) {
      return joinLines(lines, nameIndex + 1)
    }
    return trimmed
  }

  // Pass 2: heuristic trailing block detection (contact info or titles).
  let signatureStartLine: number | null = null
  let signatureLineCount = 0
  let contactSignals = 0
  let signatureSupportSignals = 0
  let affiliationSupportSignals = 0
  let sawSignOffLine = false
  let hasDirectContactInfo = false
  let bridgedTagline = false
  let sawSeparator = false

  for (let index = lastNonEmpty; index >= scanStart; index--) {
    const line = lines[index]!.trim()

    if (line.length === 0) {
      const previous = previousNonEmptyLineIndex(index, lines)
      if (
        !bridgedTagline &&
        contactSignals >= 2 &&
        previous !== null &&
        isTaglineBetweenAffiliationAndContacts(lines[previous]!, previous, lines)
      )
        continue
      if (
        shouldContinueAcrossBlankLine(
          index,
          scanStart,
          lines,
          signatureLineCount,
          signatureSupportSignals,
        )
      ) {
        signatureStartLine = index
        sawSeparator = true
        continue
      }
      if (signatureLineCount >= 2 && (contactSignals > 0 || sawSeparator)) {
        signatureStartLine = index
        break
      }
      sawSeparator = true
      continue
    }

    const isTaglineBridge =
      !bridgedTagline &&
      contactSignals >= 2 &&
      isTaglineBetweenAffiliationAndContacts(line, index, lines)
    if (isBodyProseLine(line) && !isTaglineBridge) break
    const evaluation = evaluateLine(line)
    if (evaluation.hasContactInfo) {
      contactSignals += 1
      hasDirectContactInfo =
        hasDirectContactInfo ||
        EMAIL_ADDRESS_PATTERN.test(line) ||
        CONTACT_PREFIX_PATTERN.test(line) ||
        (PHONE_PATTERN.test(line) && looksLikeStandalonePhoneLine(line, line.toLowerCase()))
    }

    if (
      signatureLineCount > 0 &&
      sawSeparator &&
      signatureSupportSignals > 0 &&
      shouldPreserveSingleNameSignOff(line, index, lines)
    ) {
      break
    }

    if (isTaglineBridge) bridgedTagline = true
    const isContinuationLine =
      signatureLineCount > 0 && (isLikelySignatureContinuation(line) || isTaglineBridge)
    if (evaluation.isLikelySignatureLine || isContinuationLine) {
      signatureLineCount += 1
      signatureStartLine = index
      if (isSignOffLineForSignatureContext(line)) {
        sawSignOffLine = true
      }
      if (hasAffiliationSignatureSignal(line, evaluation)) {
        affiliationSupportSignals += 1
      }
      if (hasStrongSignatureSignal(line, evaluation)) {
        signatureSupportSignals += 1
      }
    } else if (signatureLineCount > 0) {
      if (isSignOffLineForSignatureContext(line)) {
        sawSignOffLine = true
      }
      break
    }
  }

  if (signatureStartLine !== null) {
    if (
      contactSignals === 0 &&
      signatureSupportSignals === 0 &&
      hasBodyLikeContentAfterPotentialSignOff(signatureStartLine, lines, lastNonEmpty)
    ) {
      return trimmed
    }
    if (contactSignals >= 2 && hasContactListIntroBeforeSignature(signatureStartLine, lines)) {
      return trimmed
    }
    if (
      signatureLineCount < 3 ||
      // Links or descriptive phone labels can be an authored resource list.
      // Require a closing, email address or conventional phone row too.
      !(sawSignOffLine || hasDirectContactInfo) ||
      !(
        contactSignals >= 2 ||
        (contactSignals === 1 && (affiliationSupportSignals > 0 || sawSignOffLine))
      ) ||
      !(
        sawSignOffLine ||
        affiliationSupportSignals > 0 ||
        lines
          .slice(signatureStartLine, lastNonEmpty + 1)
          .some((line) => MULTI_WORD_NAME_PATTERN.test(line))
      )
    ) {
      return trimmed
    }
    const adjustedStart = adjustToSeparator(signatureStartLine, lines)
    return joinLines(lines, preservingSignOff(adjustedStart, lastNonEmpty, lines))
  }

  return trimmed
}

/** Requires a sign-off: extracted text cannot distinguish signatures from kept referrals. */
export function removeTrailingContactSignature(text: string): string {
  const normalized = normalizeLineEndings(text)
  const trimmed = normalized.trim()
  const lines = normalized.split('\n')
  let last = lines.length - 1
  while (last >= 0 && lines[last]!.trim().length === 0) last--
  if (last < 0 || !isTrailingSignatureContactLine(lines[last]!.trim())) return trimmed

  let start = last
  let contacts = 0
  let signOffIndex: number | null = null
  for (let index = last; index >= Math.max(0, last - 32); index--) {
    const line = lines[index]!.trim()
    if (line.length === 0) continue
    if (isSignOffLineForSignatureContext(line)) {
      signOffIndex = index
      break
    }
    // Email addresses and titles inside instructions are still body prose.
    if (
      isBodyProseLine(line) ||
      ((EMAIL_ADDRESS_PATTERN.test(line) || WEB_URL_PATTERN.test(line)) &&
        !isStrictContactLine(line))
    ) {
      break
    }
    if (isContactSignatureLine(line)) {
      if (!isTrailingSignatureContactLine(line)) {
        break
      }
      contacts++
    } else if (!isSignatureSupportLine(line)) {
      break
    }
    start = index
  }
  const removalCount = lines.slice(start, last + 1).filter((line) => line.trim().length > 0).length
  if (signOffIndex === null || contacts < 2 || removalCount < 3) return trimmed
  const result = joinLines(lines, preservingSignOff(signOffIndex, last, lines))
  // Never erase the entire extracted message.
  return result.length > 0 ? result : trimmed
}

// Markers in a reply are footers only when their entire tail is signature-like.
function hasSignatureOnlyTail(index: number, lines: string[], lastNonEmpty: number): boolean {
  if (isDelimiterLine(lines[index]!.trim())) return true
  let previous = lines[index]!.trim()
  const isLegalFooter =
    /confidential|disclaimer|notice to recipient|communication.*informational|our form crs|wire fraud/i.test(
      previous,
    )
  const isCIDFooter =
    previous.toLowerCase().startsWith('[cid:') &&
    lines.slice(Math.max(0, index - 5), index).some(isStrongSignatureSupportLine)
  let cidTailLines = 0
  for (const candidate of lines.slice(index + 1, lastNonEmpty + 1)) {
    const line = candidate.trim()
    if (line.length === 0) {
      previous = ''
      continue
    }
    const evaluation = evaluateLine(line)
    const continuesWrappedFooter =
      isLegalFooter &&
      !hasAuthoredProsePrefix(line) &&
      previous.length > 0 &&
      !/[.!?]$/.test(previous) &&
      /^[a-z]/.test(line)
    const isLegalContinuation =
      isLegalFooter &&
      LEGAL_CONTINUATION_PREFIXES.some((prefix) => line.toLowerCase().startsWith(prefix))
    const isCIDTagline =
      isCIDFooter &&
      !hasAuthoredProsePrefix(line) &&
      !isPostscriptLine(line.toLowerCase()) &&
      cidTailLines < 2 &&
      line.length <= 72 &&
      !/\d/.test(line) &&
      !/[.!?]$/.test(line)
    if (isCIDTagline) cidTailLines++
    if (!(
      evaluation.isHardIndicator ||
      isStrictContactLine(line) ||
      isStrictSupportLine(line) ||
      continuesWrappedFooter ||
      isLegalContinuation ||
      isCIDTagline
    ))
      return false
    previous = line
  }
  return true
}

function preservingSignOff(start: number, end: number, lines: string[]): number {
  const previous = previousNonEmptyLineIndex(start, lines)
  if (previous !== null && isSignOffLineForSignatureContext(lines[previous]!)) {
    const first = lines.slice(start, end + 1).find((line) => line.trim().length > 0)
    if (first && shouldPreserveSignatureNameLine(first)) start = previous
  }
  for (let index = start; index <= end; index++) {
    if (!isSignOffLineForSignatureContext(lines[index]!)) continue
    let nameIndex = index + 1
    while (nameIndex <= end && lines[nameIndex]!.trim().length === 0) nameIndex++
    if (nameIndex > end) return start
    const name = lines[nameIndex]!.trim()
    if (shouldPreserveSignatureNameLine(name)) return nameIndex + 1
    return start
  }
  return start
}

function isTaglineBetweenAffiliationAndContacts(
  line: string,
  index: number,
  lines: string[],
): boolean {
  // Only bridge known branding copy. Unknown short sentences can be authored
  // updates even inside a contact block.
  if (line.trim().toLowerCase() !== 'protecting what matters most.') return false
  const previousIndex = previousNonEmptyLineIndex(index, lines)
  if (previousIndex === null) return false
  const previous = lines[previousIndex]!.trim()
  return isStrongSignatureSupportLine(previous) || MULTI_WORD_NAME_PATTERN.test(previous)
}

function hasAuthoredProsePrefix(line: string): boolean {
  return /^(?:please|kindly|can|could|would|i|we|you|our|the|this|that|here|there|let|remember|also|attached|send|call|reply|note|use|check|review|confirm)\b/i.test(
    line.trim(),
  )
}

function isBodyProseLine(line: string): boolean {
  if (isSignOffLineForSignatureContext(line)) return false
  if (hasAuthoredProsePrefix(line) || isPostscriptLine(line.toLowerCase())) return true
  return (
    line.split(/\s+/).length > 1 &&
    /[.!?]$/.test(line) &&
    !isStrongSignatureSupportLine(line) &&
    !/\b(?:n\.a|ltd|llp)\.$/i.test(line)
  )
}

function isStrictSupportLine(line: string): boolean {
  if (isBodyProseLine(line)) return false
  return (
    isStrongSignatureSupportLine(line) ||
    SINGLE_NAME_PATTERN.test(line) ||
    MULTI_WORD_NAME_PATTERN.test(line) ||
    isSignOffLineForSignatureContext(line)
  )
}

// Email/URL matches must leave only a contact label, name or affiliation around them.
function isStrictContactLine(line: string): boolean {
  if (isBodyProseLine(line)) return false
  if (STANDALONE_CONTACT_LABEL_PATTERN.test(line) || DESCRIPTIVE_PHONE_LINE_PATTERN.test(line))
    return true
  const patterns = [EMAIL_ADDRESS_PATTERN, WEB_URL_PATTERN, PHONE_PATTERN]
  if (!patterns.some((pattern) => pattern.test(line))) return false
  let remainder = line
  for (const pattern of patterns)
    remainder = remainder.replace(
      new RegExp(pattern.source, pattern.flags.replace('g', '') + 'g'),
      ' ',
    )
  remainder = remainder
    .replace(/[|•│┃¦<>():+.,/-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return (
    remainder.length === 0 ||
    STANDALONE_CONTACT_LABEL_PATTERN.test(remainder) ||
    /^(?:tel|phone|mobile|office|direct|fax|cell)$/i.test(remainder) ||
    isStrictSupportLine(remainder)
  )
}

// MARK: - Line evaluation

function evaluateLine(line: string): LineEvaluation {
  const trimmed = line.trim()
  const lowercased = trimmed.toLowerCase()

  const isDelimiter = SIGNATURE_DELIMITER_PATTERN.test(trimmed)
  const isCidLine = lowercased.startsWith('[cid:')
  // DOM opener vocabulary relies on surrounding structure. Plain text needs
  // a complete boilerplate statement; an opener cannot swallow instructions
  // in the same paragraph.
  const hasLegalOpener =
    /^this e-?mail (?:is confidential|may contain (?:confidential(?: or privileged)?|privileged(?: or confidential)?) information)(?: intended (?:only|solely) for the (?:intended )?recipient)?\.?$/i.test(
      trimmed,
    )
  const isPreferenceFooter =
    /^update your preferences(?:\s*:?\s+(?:https?:\/\/|www\.)\S+)?[.!]?$/i.test(trimmed)
  const hasHardFragment =
    hasLegalOpener ||
    isPreferenceFooter ||
    HARD_INDICATOR_FRAGMENTS.some(
      (fragment) =>
        lowercased.startsWith(fragment) ||
        new RegExp(`[.!?]\\s+${fragment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`).test(lowercased),
    )
  const hasContactPrefix =
    CONTACT_PREFIX_PATTERN.test(trimmed) || DESCRIPTIVE_PHONE_LINE_PATTERN.test(trimmed)
  const hasStandaloneContactLabel = STANDALONE_CONTACT_LABEL_PATTERN.test(trimmed)

  const hasEmail = EMAIL_ADDRESS_PATTERN.test(trimmed)
  const hasUrl = WEB_URL_PATTERN.test(trimmed)
  const hasPhoneCandidate = PHONE_PATTERN.test(trimmed)
  const hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased)

  const hasContactInfo =
    hasContactPrefix || hasEmail || hasUrl || hasStandalonePhone || hasStandaloneContactLabel

  const isHardIndicator = isDelimiter || isCidLine || hasHardFragment

  let score = 0
  if (isSignOffLine(lowercased)) score += 1
  if (hasContactInfo) score += 3
  if (containsKeyword(lowercased, TITLE_KEYWORDS)) score += 1
  if (containsAddressKeyword(lowercased)) score += 1
  if (trimmed.length <= 72) score += 1
  if (containsSignatureSeparator(trimmed)) score += 1

  if (looksLikeSentence(trimmed)) score -= 1
  if (isListItem(trimmed)) score -= 2

  return {
    isHardIndicator,
    isLikelySignatureLine: score >= 2,
    hasContactInfo,
  }
}

function looksLikeStandalonePhoneLine(trimmed: string, lowercased: string): boolean {
  let letters = 0
  let digits = 0
  for (const ch of trimmed) {
    if (/\p{L}/u.test(ch)) letters += 1
    if (/\p{Nd}/u.test(ch)) digits += 1
  }

  if (digits < 7) return false
  if (trimmed.length > 40) return false

  if (letters === 0) {
    return true
  }

  if (letters <= 3) {
    if (lowercased.includes('ext') || lowercased.includes(' x') || lowercased.endsWith('x')) {
      return true
    }
  }

  return false
}

function isSignOffLine(lowercased: string): boolean {
  const normalized = lowercased.trim()
  for (const signOff of SIGN_OFF_WORDS) {
    if (normalized === signOff || normalized === `${signOff},`) {
      return true
    }
  }
  return false
}

function isSignOffLineForSignatureContext(line: string): boolean {
  const normalized = line
    .toLowerCase()
    .trim()
    .replace(/^\p{P}+/u, '')
    .replace(/\p{P}+$/u, '')
  return SIGN_OFF_WORDS.has(normalized)
}

function looksLikeSentence(line: string): boolean {
  if (line.length <= 40) return false
  return line.endsWith('.') || line.endsWith('!') || line.endsWith('?')
}

function containsKeyword(text: string, keywords: readonly string[]): boolean {
  return keywords.some((keyword) => text.includes(keyword))
}

function containsAddressKeyword(lowercased: string): boolean {
  return ADDRESS_KEYWORD_PATTERN.test(lowercased)
}

function containsSignatureSeparator(text: string): boolean {
  return text.includes('|') || text.includes('│') || text.includes('┃') || text.includes('¦')
}

// MARK: - Signature range helpers

function findSignatureStartLine(indicatorIndex: number, lines: string[]): number {
  let foundShortLines = false
  let signatureStartLine: number | null = null

  const upperBound = Math.min(indicatorIndex - 1, lines.length - 1)
  if (upperBound < 0) return indicatorIndex

  for (let index = upperBound; index >= 0; index--) {
    const line = lines[index]!.trim()

    if (line.length === 0) {
      if (foundShortLines) {
        if (shouldContinueAcrossBlankLineInHardIndicatorScan(index, lines)) {
          signatureStartLine = index
          continue
        }
        signatureStartLine = index
        break
      }
      continue
    }

    if (isBodyProseLine(line)) break
    const evaluation = evaluateLine(line)
    if (!foundShortLines && shouldPreserveSingleNameSignOff(line, index, lines)) {
      break
    }
    if (foundShortLines && shouldPreserveSingleNameSignOff(line, index, lines)) {
      break
    }

    if (
      evaluation.isHardIndicator ||
      evaluation.isLikelySignatureLine ||
      looksLikeSignatureLine(line)
    ) {
      foundShortLines = true
    } else {
      break
    }
  }

  return signatureStartLine ?? indicatorIndex
}

function shouldContinueAcrossBlankLineInHardIndicatorScan(index: number, lines: string[]): boolean {
  let probe = index - 1
  let blankLinesSeen = 0

  while (probe >= 0) {
    const candidate = lines[probe]!.trim()
    if (candidate.length === 0) {
      blankLinesSeen += 1
      if (blankLinesSeen > 1) {
        return false
      }
      probe -= 1
      continue
    }

    if (shouldPreserveSingleNameSignOff(candidate, probe, lines)) {
      return true
    }

    if (isBodyProseLine(candidate)) return false
    const evaluation = evaluateLine(candidate)
    if (
      evaluation.isHardIndicator ||
      evaluation.hasContactInfo ||
      evaluation.isLikelySignatureLine ||
      isLikelySignatureContinuation(candidate)
    ) {
      return true
    }

    return false
  }

  return false
}

function adjustToSeparator(startLine: number, lines: string[]): number {
  const previousIndex = startLine - 1
  if (previousIndex >= 0) {
    const previousLine = lines[previousIndex]!.trim()
    if (previousLine.length === 0) {
      return previousIndex
    }
  }
  return startLine
}

function looksLikeSignatureLine(line: string): boolean {
  const trimmed = line.trim()
  if (trimmed.length === 0) return false
  if (isListItem(trimmed)) return false

  const shortEnough = trimmed.length <= 80
  const noSentenceEnding = !(
    trimmed.endsWith('.') ||
    trimmed.endsWith('!') ||
    trimmed.endsWith('?')
  )
  const lowercased = trimmed.toLowerCase()
  const hasContactPrefix =
    CONTACT_PREFIX_PATTERN.test(trimmed) || DESCRIPTIVE_PHONE_LINE_PATTERN.test(trimmed)
  const hasStandaloneContactLabel = STANDALONE_CONTACT_LABEL_PATTERN.test(trimmed)
  const hasEmail = EMAIL_ADDRESS_PATTERN.test(trimmed)
  const hasUrl = WEB_URL_PATTERN.test(trimmed)
  const hasPhoneCandidate = PHONE_PATTERN.test(trimmed)
  const hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased)

  if (hasContactPrefix || hasStandaloneContactLabel || hasEmail || hasUrl || hasStandalonePhone) {
    return true
  }

  if (containsKeyword(lowercased, ORGANIZATION_KEYWORDS)) {
    return true
  }

  return shortEnough && (noSentenceEnding || trimmed.endsWith(','))
}

function shouldPreserveSingleNameSignOff(line: string, index: number, lines: string[]): boolean {
  const trimmed = line.trim()
  if (!SINGLE_NAME_PATTERN.test(trimmed)) return false

  const lowercasedTrimmed = trimmed.toLowerCase()
  const nextLine = nextNonEmptyLine(index, lines)
  if (nextLine !== null) {
    const nextEvaluation = evaluateLine(nextLine)
    const hasSignatureContextBelow =
      nextEvaluation.hasContactInfo ||
      nextEvaluation.isHardIndicator ||
      nextEvaluation.isLikelySignatureLine ||
      isLikelySignatureContinuation(nextLine)

    if (hasSignatureContextBelow) {
      const normalizedNext = nextLine.trim().toLowerCase()
      const expandsSameName = normalizedNext.startsWith(`${lowercasedTrimmed} `)
      if (!expandsSameName) {
        return false
      }
    }
  }

  let previousIndex = index - 1
  while (previousIndex >= 0) {
    const previous = lines[previousIndex]!.trim()
    if (previous.length === 0) {
      previousIndex -= 1
      continue
    }

    const previousLowercased = previous.toLowerCase()
    if (isSignOffLine(previousLowercased)) {
      return false
    }

    const previousEvaluation = evaluateLine(previous)
    if (
      previousEvaluation.hasContactInfo ||
      previousEvaluation.isHardIndicator ||
      previousEvaluation.isLikelySignatureLine ||
      isLikelySignatureContinuation(previous)
    ) {
      return false
    }

    return true
  }

  return true
}

function nextNonEmptyLine(index: number, lines: string[]): string | null {
  let probe = index + 1
  while (probe < lines.length) {
    const candidate = lines[probe]!.trim()
    if (candidate.length > 0) {
      return candidate
    }
    probe += 1
  }
  return null
}

function hasContactListIntroBeforeSignature(startLine: number, lines: string[]): boolean {
  const previousIndex = previousNonEmptyLineIndex(startLine, lines)
  if (previousIndex === null) return false
  return isContactListIntroLine(lines[previousIndex]!)
}

function isContactListIntroLine(line: string): boolean {
  const lowercased = line.trim().toLowerCase()
  return lowercased.endsWith(':') && CONTACT_LIST_INTRO_KEYWORDS.some((k) => lowercased.includes(k))
}

function preservesPostscriptAfterSignOff(lines: string[], lastNonEmpty: number): boolean {
  if (!isPostscriptLine(lines[lastNonEmpty]!.trim().toLowerCase())) {
    return false
  }

  const nameIndex = previousNonEmptyLineIndex(lastNonEmpty, lines)
  if (nameIndex === null) return false
  const signOffIndex = previousNonEmptyLineIndex(nameIndex, lines)
  if (signOffIndex === null) return false

  const nameLine = lines[nameIndex]!.trim()
  const signOffLine = lines[signOffIndex]!.trim()

  const isNameLine = SINGLE_NAME_PATTERN.test(nameLine) || MULTI_WORD_NAME_PATTERN.test(nameLine)

  return isNameLine && isSignOffLine(signOffLine.toLowerCase())
}

function hasBodyLikeContentAfterPotentialSignOff(
  startLine: number,
  lines: string[],
  lastNonEmpty: number,
): boolean {
  let sawSignOffLikeLine = false

  for (let index = startLine; index <= lastNonEmpty; index++) {
    const line = lines[index]!.trim()
    if (line.length === 0) continue

    const lowercased = line.toLowerCase()
    const isNameLine = SINGLE_NAME_PATTERN.test(line) || MULTI_WORD_NAME_PATTERN.test(line)
    const isPotentialSignOffLine = isSignOffLine(lowercased) || isNameLine || isDelimiterLine(line)

    if (isPotentialSignOffLine) {
      sawSignOffLikeLine = true
      continue
    }

    if (!sawSignOffLikeLine) return false

    if (isPostscriptLine(lowercased)) {
      return true
    }

    const evaluation = evaluateLine(line)
    return (
      !evaluation.isHardIndicator &&
      !evaluation.hasContactInfo &&
      !evaluation.isLikelySignatureLine &&
      !isLikelySignatureContinuation(line)
    )
  }

  return false
}

function previousNonEmptyLineIndex(index: number, lines: string[]): number | null {
  let probe = index - 1
  while (probe >= 0) {
    if (lines[probe]!.trim().length > 0) {
      return probe
    }
    probe -= 1
  }
  return null
}

function isPostscriptLine(lowercased: string): boolean {
  const trimmed = lowercased.trim()
  return (
    trimmed.startsWith('p.s.') ||
    trimmed.startsWith('p.s:') ||
    trimmed.startsWith('ps.') ||
    trimmed.startsWith('ps:')
  )
}

function shouldContinueAcrossBlankLine(
  index: number,
  scanStart: number,
  lines: string[],
  signatureLineCount: number,
  signatureSupportSignals: number,
): boolean {
  if (signatureLineCount <= 0) return false

  let probe = index - 1
  let blankLinesSeen = 0
  while (probe >= scanStart) {
    const candidate = lines[probe]!.trim()
    if (candidate.length === 0) {
      blankLinesSeen += 1
      if (blankLinesSeen > 1) {
        return false
      }
      probe -= 1
      continue
    }

    if (signatureSupportSignals > 0 && shouldPreserveSingleNameSignOff(candidate, probe, lines)) {
      return true
    }

    const evaluation = evaluateLine(candidate)
    if (
      evaluation.isLikelySignatureLine ||
      evaluation.hasContactInfo ||
      hasStrongSignatureSignal(candidate, evaluation) ||
      isLikelySignatureContinuation(candidate)
    ) {
      return true
    }

    return false
  }

  return false
}

function isLikelySignatureContinuation(line: string): boolean {
  const trimmed = line.trim()
  if (trimmed.length === 0) return false
  if (isListItem(trimmed)) return false

  const lowercased = trimmed.toLowerCase()
  if (isSignOffLine(lowercased)) return true
  if (SINGLE_NAME_PATTERN.test(trimmed) || MULTI_WORD_NAME_PATTERN.test(trimmed)) {
    return true
  }
  if (
    containsKeyword(lowercased, TITLE_KEYWORDS) ||
    containsKeyword(lowercased, ORGANIZATION_KEYWORDS) ||
    containsAddressKeyword(lowercased)
  ) {
    return true
  }
  if (containsSignatureSeparator(trimmed)) {
    return true
  }

  const hasContactPrefix =
    CONTACT_PREFIX_PATTERN.test(trimmed) || DESCRIPTIVE_PHONE_LINE_PATTERN.test(trimmed)
  const hasEmail = EMAIL_ADDRESS_PATTERN.test(trimmed)
  const hasUrl = WEB_URL_PATTERN.test(trimmed)
  const hasPhoneCandidate = PHONE_PATTERN.test(trimmed)
  const hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased)
  if (hasContactPrefix || hasEmail || hasUrl || hasStandalonePhone) {
    return true
  }

  // City/state/postal rows only; comma-plus-digits also matched calendar dates.
  if (/^[A-Za-z][A-Za-z .'-]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?$/.test(trimmed)) return true

  return false
}

function hasStrongSignatureSignal(line: string, evaluation: LineEvaluation): boolean {
  const trimmed = line.trim()
  if (trimmed.length === 0) return false

  const lowercased = trimmed.toLowerCase()
  if (evaluation.hasContactInfo || evaluation.isHardIndicator) {
    return true
  }
  if (containsSignatureSeparator(trimmed)) {
    return true
  }
  if (
    containsKeyword(lowercased, TITLE_KEYWORDS) ||
    containsKeyword(lowercased, ORGANIZATION_KEYWORDS) ||
    containsAddressKeyword(lowercased)
  ) {
    return true
  }

  return false
}

function hasAffiliationSignatureSignal(line: string, evaluation: LineEvaluation): boolean {
  const trimmed = line.trim()
  if (trimmed.length === 0) return false

  const lowercased = trimmed.toLowerCase()
  if (containsSignatureSeparator(trimmed)) {
    return true
  }
  if (
    containsKeyword(lowercased, TITLE_KEYWORDS) ||
    containsKeyword(lowercased, ORGANIZATION_KEYWORDS) ||
    containsAddressKeyword(lowercased)
  ) {
    return true
  }
  if (evaluation.isHardIndicator && !evaluation.hasContactInfo) {
    return true
  }

  return false
}

// MARK: - Utilities

function joinLines(lines: string[], endLine: number): string {
  const endIndex = Math.max(0, Math.min(endLine, lines.length))
  return lines.slice(0, endIndex).join('\n').trim()
}

function isDelimiterLine(line: string): boolean {
  return SIGNATURE_DELIMITER_PATTERN.test(line)
}
