// Port of RepeatedSignatureRemover.swift.
// Recognizes otherwise unknown corporate footers by an exact repeat in quoted
// history. Only the complete trailing block is eligible, so a new postscript
// stays visible.

import { isTrailingSignatureContactLine } from './html'
import {
  SIGNATURE_SUPPORT_PROSE_PATTERN,
  SIGN_OFF_PHRASES,
  isAuthoredLeadInLine,
  isStrongSignatureSupportLine,
  shouldPreserveSignatureNameLine,
} from './patterns'
import { isPostscriptLine } from './signature'

// Outlook's plain alternative adds link destinations to older quoted copies.
const LINK_TARGET_PATTERN = /<(?:https?:\/\/|mailto:|tel:)[^<>\s]+>/gi

/**
 * Removes a trailing signature block whose full text repeats verbatim in the
 * message's quoted history. `quotedText` is invoked only once a sign-off, a
 * preserved name, a strong title line and corroborating contact rows survive
 * the heuristics, so an ordinary message never pays for the projection.
 */
export function removeRepeatedSignature(text: string, quotedText: () => string): string {
  const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n')
  const nonEmpty: number[] = []
  for (let index = 0; index < lines.length; index++) {
    if (lines[index]!.trim().length > 0) nonEmpty.push(index)
  }
  if (nonEmpty.length < 6) return text

  let normalizedHistory: string | null = null
  // Work backward: "Thank you!" can precede the actual "Sincerely," closing.
  for (let position = nonEmpty.length - 1; position >= 0; position--) {
    if (position <= 0 || position + 4 >= nonEmpty.length) continue
    const start = nonEmpty[position]!
    const name = nonEmpty[position + 1]!
    // A lead-in introduces an authored example or template, even if it is repeated.
    if (isAuthoredLeadInLine(lines[nonEmpty[position - 1]!]!)) continue
    if (
      !isSignOff(lines[start]!) ||
      isSignOff(lines[name]!) ||
      !shouldPreserveSignatureNameLine(lines[name]!) ||
      !isStrongSignatureSupportLine(lines[nonEmpty[position + 2]!]!)
    ) {
      continue
    }
    if (
      nonEmpty.slice(position + 2).some((index) => isPostscriptLine(lines[index]!.toLowerCase()))
    ) {
      continue
    }

    const contactWindow = nonEmpty.slice(position + 3, Math.min(nonEmpty.length, position + 15))
    let contactCount = 0
    for (const index of contactWindow) {
      const line = lines[index]!
      if (isTrailingSignatureContactLine(line)) {
        contactCount += 1
      } else if (SIGNATURE_SUPPORT_PROSE_PATTERN.test(line)) {
        break
      }
    }
    if (contactCount < 2) continue

    if (normalizedHistory === null) {
      normalizedHistory = ' ' + normalizedForComparison(quotedText()) + ' '
    }
    const suffix = normalizedForComparison(lines.slice(start).join('\n'))
    // Spaces bound the match to whole words, including the final word of the footer.
    if (!normalizedHistory.includes(' ' + suffix + ' ')) continue
    return lines
      .slice(0, name + 1)
      .join('\n')
      .trim()
  }
  return text
}

function isSignOff(line: string): boolean {
  const trimmed = line
    .trim()
    .replace(/^\p{P}+/u, '')
    .replace(/\p{P}+$/u, '')
    .toLowerCase()
  return SIGN_OFF_PHRASES.has(trimmed)
}

function normalizedForComparison(text: string): string {
  const visibleText = text.replace(LINK_TARGET_PATTERN, '')
  return visibleText
    .split(/\s+/)
    .filter((word) => word.length > 0)
    .join(' ')
}
