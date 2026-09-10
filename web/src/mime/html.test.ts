import { describe, expect, it } from 'vitest'
import { isStrongSignatureSupportLine, shouldPreserveSignatureNameLine } from './patterns'
import { removeQuotesFromHtml } from './html'
import { paragraphAwareText, parseHtmlDocument } from './htmlText'

function cleanedText(html: string): string {
  const cleanedHTML = removeQuotesFromHtml(html, 'quotedAndSignatures') ?? html
  return paragraphAwareText(parseHtmlDocument(cleanedHTML).body).trim()
}

function messageWithTrailingSignature(bodyLine: string, phoneLine = '415-555-1212'): string {
  return `
    <div>Current reply.</div>
    <div>${bodyLine}</div>
    <div>John Smith</div>
    <div>Partner</div>
    <div>john@example.test</div>
    <div>${phoneLine}</div>
  `
}

describe('HTML contact-signature phone classification', () => {
  // Revert-check: separator collapse, labelled business hours, descriptive phone labels.
  it.each([
    'Office: 770-555-0148 | Fax: 770-555-0149',
    'T: 415-555-1212 | F: 650-555-1213',
    'P: 415-555-1212 | M: 650-555-1213',
    'Cell: 415-555-1212 | Office: 650-555-1213',
    'Office: 914-564-1325 | Monday - Friday | 9am - 5pm',
    'Office: 914-564-1325 | Mon–Fri 9am–5pm',
    'Phone: 914-564-1325 | 24/7',
    'Emergency line after hours: 914-373-4658',
    'After hours: 914-373-4658',

    'T 415-555-1212 | x112',
    'T 415-555-1212, ext. 112',
    'T 415-555-1212 / F 650-555-1212',
    'T: 415-555-1212 F: 650-555-1213',
    'Phone Number: 415-555-1212',
    'T +١٢٣ ٤٥٦ ٧٨٩٠',
    'T ４１５-５５５-１２１２',
  ])('removes a trailing signature ending in %s', (phoneLine) => {
    expect(cleanedText(messageWithTrailingSignature('', phoneLine))).toBe('Current reply.')
  })

  it.each([
    'Can you give me a call? 415-283-6379',
    'Invoice: 12345678',
    'Invoice Number | 12345678',
    'Deadline: 8-15-2026',
    'P2026-0815',
  ])('preserves authored content that resembles contact data: %s', (bodyLine) => {
    const result = cleanedText(messageWithTrailingSignature(bodyLine))

    expect(result).toContain('Current reply.')
    expect(result).toContain(bodyLine)
    expect(result).not.toContain('John Smith')
    expect(result).not.toContain('john@example.test')
  })
})

describe('signature classifier preservation', () => {
  // Revert-check: rejected modifiers/descriptive labels must keep the entire candidate block.
  it.each([
    'Office: 914-564-1325 | call me anytime',
    'Phone: 914-564-1325 | Invoice 12345',
    '914-564-1325 | Mon-Fri 9am-5pm',
    'Call the emergency line: 914-373-4658.',
    'Reference line: 12345678',
    'Office reference: 914-373-4658',
    'Emergency line: 08-15-2026',
    'Emergency line: 12345678',
  ])('preserves an unclassified final line: %s', (line) => {
    expect(cleanedText(messageWithTrailingSignature('', line))).toContain('John Smith')
  })
  it('matches name/title words without matching prose substrings', () => {
    // Revert-check: shared name/contact word boundaries and strong-support prose guard.
    expect(shouldPreserveSignatureNameLine('Marcella Ruiz')).toBe(true)
    expect(shouldPreserveSignatureNameLine('Persephone Lee')).toBe(true)
    for (const title of [
      'Loan Officer',
      'Chief Executive Officer',
      'Fairfax Insurance Agency',
      'Acme Inc.',
      'Co-Founder',
    ]) {
      expect(isStrongSignatureSupportLine(title)).toBe(true)
    }
    expect(isStrongSignatureSupportLine('The homeowner will coordinate with the broker.')).toBe(
      false,
    )
    expect(shouldPreserveSignatureNameLine('Partner')).toBe(false)
  })
})
