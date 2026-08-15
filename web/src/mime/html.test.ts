import { describe, expect, it } from 'vitest'
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
  it.each([
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
