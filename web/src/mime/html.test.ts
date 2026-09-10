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

describe('confirmed signature tails', () => {
  // Revert-check: bounded tail skip and trailing image-only extension.
  it.each([
    'Protecting what matters most.',
    'Auto | Home | Life | Business',
    'Licensed in GA, AL and TN - NPN 1234567',
  ])('removes a bounded tail: %s', (tail) => {
    const html = messageWithTrailingSignature('') + `<p>${tail}</p><p><img src="cid:badge"></p>`
    expect(cleanedText(html)).toBe('Current reply.')
    expect(removeQuotesFromHtml(html)).not.toContain('cid:badge')
  })
  it('preserves a contact list followed by a final body sentence', () => {
    const html =
      '<p>Please contact:</p><p>Jane Doe</p><p>jane@example.test</p><p>415-555-1212</p><p>Please pick one.</p>'
    expect(cleanedText(html)).toContain('jane@example.test')
    expect(cleanedText(html)).toContain('Please pick one.')
  })
  it('removes paragraph-start legal notices and preserves inline discussion', () => {
    // Revert-check: anchored shared legal openers plus visible-line-start guard.
    expect(
      cleanedText(
        messageWithTrailingSignature('') +
          '<p>CONFIDENTIALITY NOTICE: This e-mail and any attachments are for the exclusive use of the intended recipient.</p>',
      ),
    ).toBe('Current reply.')
    const html = '<p>Please read the <b>confidentiality notice:</b> it changed.</p>'
    expect(cleanedText(html)).toBe('Please read the confidentiality notice: it changed.')
  })
})

// Revert-check: short authored sentences are not branding taglines.
it.each(['P.S. Bring the draft.', 'Please bring the draft.', 'The estimate changed.'])(
  'preserves a post-signature instruction: %s',
  (tail) => {
    expect(cleanedText(messageWithTrailingSignature('') + `<p>${tail}</p>`)).toContain(tail)
  },
)
describe('signature sub-lines and sign-off policy', () => {
  const contact = 'Best,<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212'
  // Revert-check: scoped sub-line expansion and preserved authored prefix/name.
  it.each([
    `<div>Current reply.<br>${contact}</div>`,
    `<p>Current reply.</p><p>${contact}</p>`,
    `<table><tr><td>Current reply.<br>${contact}</td></tr></table>`,
    `<p>Current reply.</p><table><tr><td><img src="cid:badge"></td><td>${contact}</td></tr></table>`,
  ])('removes only the contact block in %s', (html) => {
    const result = cleanedText(html)
    expect(result).toContain('Current reply.')
    expect(result).toContain('Best,')
    expect(result).toContain('John Smith')
    expect(result).not.toContain('Partner')
    expect(result).not.toContain('john@example.test')
    expect(removeQuotesFromHtml(html)).not.toContain('cid:badge')
  })
  it('preserves contact lists and reference lines in a shared block', () => {
    const list =
      '<div>Please contact:<br>Alice: alice@example.test<br>Bob: bob@example.test<br>415-555-1212</div>'
    expect(cleanedText(list)).toContain('Bob: bob@example.test')
    const reference =
      '<div>Current reply.<br>Invoice | 12345678<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212</div>'
    expect(cleanedText(reference)).toContain('Invoice | 12345678')
    expect(cleanedText(reference)).not.toContain('John Smith')
  })
  it('removes bounded product fillers but preserves a postscript', () => {
    const html =
      '<p>Current reply.</p><p>Best,</p><p>John Smith</p><p>Partner</p><p>Auto | Home | Life | Business</p><p>john@example.test</p><p>415-555-1212</p>'
    expect(cleanedText(html)).not.toContain('Auto')
    expect(cleanedText(html)).toContain('John Smith')
    expect(cleanedText(html + '<p>P.S. Bring the draft.</p>')).toContain('P.S. Bring the draft.')
  })
  it.each(['Partner', 'Threash Insurance Agency'])(
    'does not preserve a title/company as a name: %s',
    (name) => {
      for (const signature of [
        `<div class="gmail_signature">Best,<br>${name}<br>john@example.test<br>415-555-1212</div>`,
        `<p>Best,</p><p>${name}</p><p>john@example.test</p><p>415-555-1212</p>`,
      ]) {
        expect(cleanedText('<p>Current reply.</p>' + signature)).toBe('Current reply.')
      }
    },
  )
})

it('keeps the fourth trailing image when cutting inside a shared block', () => {
  // Revert-check: text-node truncation stops at the owner block rather than deleting later images.
  const html =
    '<div>Current reply.<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212</div>' +
    [1, 2, 3, 4].map((n) => `<p><img src="cid:photo${n}"></p>`).join('')
  const cleaned = removeQuotesFromHtml(html)
  expect(cleaned).toContain('cid:photo4')
  expect(cleaned).not.toContain('cid:photo3')
})
