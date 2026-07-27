// Plain-text signature/boilerplate removal.
// Port of esc-chatmail/Services/TextProcessing/PlainTextSignatureRemover.swift.

import {
  ADDRESS_KEYWORD_PATTERN,
  EMAIL_ADDRESS_PATTERN,
  PHONE_PATTERN,
  SIGNATURE_DELIMITER_PATTERN,
  STANDALONE_CONTACT_LABEL_PATTERN,
  WEB_URL_PATTERN,
} from './patterns'
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
  'important:',
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

const SIGN_OFF_WORDS = new Set([
  'regards',
  'thanks',
  'thank you',
  'best',
  'cheers',
  'sincerely',
  'yours truly',
  'best wishes',
  'best regards',
  'kind regards',
  'warm regards',
  'take care',
  'all the best',
])

const CONTACT_PREFIX_PATTERN =
  /^(m|c|o|f|d|t|p|tel|phone|mobile|office|direct|fax)\s*(?:[:.-]\s*\S+|\(?\+?\d[\d\s().-]{5,}\b)/i

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
  const nonEmptyLineCount = lines.reduce(
    (count, line) => (line.trim().length > 0 ? count + 1 : count),
    0,
  )

  // Pass 1: definitive signature indicators near the end.
  let earliestHardIndicator: number | null = null
  for (let index = lastNonEmpty; index >= scanStart; index--) {
    const line = lines[index]!.trim()
    if (line.length === 0) continue

    const evaluation = evaluateLine(line)
    if (evaluation.isHardIndicator) {
      earliestHardIndicator = index
    }
  }
  if (earliestHardIndicator !== null) {
    const hardIndicatorLine = lines[earliestHardIndicator]!.trim()
    if (isDelimiterLine(hardIndicatorLine)) {
      return joinLines(lines, earliestHardIndicator)
    }
    const startLine = findSignatureStartLine(earliestHardIndicator, lines)
    return joinLines(lines, startLine)
  }

  // Pass 2: heuristic trailing block detection (contact info or titles).
  let signatureStartLine: number | null = null
  let signatureLineCount = 0
  let contactSignals = 0
  let signatureSupportSignals = 0
  let affiliationSupportSignals = 0
  let sawSignOffLine = false
  let sawSeparator = false

  for (let index = lastNonEmpty; index >= scanStart; index--) {
    const line = lines[index]!.trim()

    if (line.length === 0) {
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

    const evaluation = evaluateLine(line)
    if (evaluation.hasContactInfo) {
      contactSignals += 1
    }

    if (
      signatureLineCount > 0 &&
      sawSeparator &&
      signatureSupportSignals > 0 &&
      shouldPreserveSingleNameSignOff(line, index, lines)
    ) {
      break
    }

    const isContinuationLine = signatureLineCount > 0 && isLikelySignatureContinuation(line)
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
    if (
      contactSignals >= 2 &&
      affiliationSupportSignals === 0 &&
      !sawSignOffLine &&
      hasContactListIntroBeforeSignature(signatureStartLine, lines)
    ) {
      return trimmed
    }
    const totalChars = trimmed.length
    if (contactSignals === 0 && nonEmptyLineCount <= 4 && totalChars < 180) {
      return trimmed
    }
    if (
      contactSignals === 1 &&
      signatureLineCount <= 1 &&
      !hasSupportingSignatureContext(signatureStartLine, lines, lastNonEmpty)
    ) {
      return trimmed
    }
    const adjustedStart = adjustToSeparator(signatureStartLine, lines)
    return joinLines(lines, adjustedStart)
  }

  return trimmed
}

// MARK: - Line evaluation

function evaluateLine(line: string): LineEvaluation {
  const trimmed = line.trim()
  const lowercased = trimmed.toLowerCase()

  const isDelimiter = SIGNATURE_DELIMITER_PATTERN.test(trimmed)
  const isCidLine = lowercased.startsWith('[cid:')
  const hasHardFragment = HARD_INDICATOR_FRAGMENTS.some((fragment) => lowercased.includes(fragment))
  const hasContactPrefix = CONTACT_PREFIX_PATTERN.test(trimmed)
  const hasStandaloneContactLabel = STANDALONE_CONTACT_LABEL_PATTERN.test(trimmed)

  const hasEmail = EMAIL_ADDRESS_PATTERN.test(trimmed)
  const hasUrl = WEB_URL_PATTERN.test(trimmed)
  const hasPhoneCandidate = PHONE_PATTERN.test(trimmed)
  const hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased)

  const hasContactInfo =
    hasContactPrefix || hasEmail || hasUrl || hasStandalonePhone || hasStandaloneContactLabel

  const isHardIndicator = isDelimiter || isCidLine || hasHardFragment || hasContactPrefix

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
  const hasContactPrefix = CONTACT_PREFIX_PATTERN.test(trimmed)
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

function hasSupportingSignatureContext(
  startLine: number,
  lines: string[],
  lastNonEmpty: number,
): boolean {
  const lookbackStart = Math.max(0, startLine - 4)
  for (let index = startLine - 1; index >= lookbackStart; index--) {
    const line = lines[index]!.trim()
    if (line.length === 0) continue

    const lowercased = line.toLowerCase()
    const evaluation = evaluateLine(line)
    if (
      isSignOffLine(lowercased) ||
      evaluation.hasContactInfo ||
      evaluation.isHardIndicator ||
      containsKeyword(lowercased, TITLE_KEYWORDS) ||
      containsKeyword(lowercased, ORGANIZATION_KEYWORDS) ||
      containsAddressKeyword(lowercased)
    ) {
      return true
    }
  }

  let contactLineCount = 0
  for (let index = startLine; index <= lastNonEmpty; index++) {
    const line = lines[index]!.trim()
    if (line.length === 0) continue

    const evaluation = evaluateLine(line)
    if (evaluation.hasContactInfo) {
      contactLineCount += 1
      if (contactLineCount >= 2) {
        return true
      }
    }
  }

  return false
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

  const hasContactPrefix = CONTACT_PREFIX_PATTERN.test(trimmed)
  const hasEmail = EMAIL_ADDRESS_PATTERN.test(trimmed)
  const hasUrl = WEB_URL_PATTERN.test(trimmed)
  const hasPhoneCandidate = PHONE_PATTERN.test(trimmed)
  const hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased)
  if (hasContactPrefix || hasEmail || hasUrl || hasStandalonePhone) {
    return true
  }

  // Address-style continuation line (e.g., "New York, NY 10013")
  if (trimmed.length <= 72 && trimmed.includes(',') && /\d/.test(trimmed)) {
    return true
  }

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
