import { describe, expect, it } from 'vitest'
import { removeQuotesFromHtml } from './html'
import { paragraphAwareText, parseHtmlDocument } from './htmlText'

const email = '<a href="mailto:jane@example.test">Email me</a>'
const phone = '<a href="tel:+14155551212">Call the office</a>'
const text = (html: string) =>
  paragraphAwareText(parseHtmlDocument(removeQuotesFromHtml(html) ?? html).body)
    .replace(/\s+/g, ' ')
    .trim()
const paragraphs = (lines: string[]) => lines.map((line) => `<p>${line}</p>`).join('')
const signed = (contacts: string[]) =>
  paragraphs(['The estimate is ready.', 'Best,', 'Jane Doe', ...contacts])

describe('F12 DOM signature lookback', () => {
  // Revert-check: DOM_SIGNATURE_LOOKBACK in truncateTrailingContactSignature, not the F1 fallback.
  it.each([false, true])('removes long email-only signatures; blank separators: %s', (blanks) => {
    const contacts = Array.from({ length: 38 }, (_, i) => `contact${i}@example.test`)
    expect(text(signed(contacts.flatMap((line) => (blanks ? ['', line] : [line]))))).toBe(
      'The estimate is ready. Best, Jane Doe',
    )
  })
  it('includes the signoff exactly 80 slots before the final contact', () => {
    expect(text(signed(Array.from({ length: 79 }, (_, i) => `contact${i}@example.test`)))).toBe(
      'The estimate is ready. Best, Jane Doe',
    )
  })
  it('preserves a comparable block whose signoff is beyond 80 slots', () => {
    const html = signed(Array.from({ length: 80 }, (_, i) => `contact${i}@example.test`))
    expect(text(html)).toContain('contact0@example.test')
    expect(text(html)).toContain('contact79@example.test')
  })
  it('preserves a contact introduction outside the old window', () => {
    const html = paragraphs([
      'Please email these contacts:',
      'Jane Doe',
      'Partner',
      ...Array.from({ length: 38 }, (_, i) => `contact${i}@example.test`),
    ])
    expect(text(html)).toContain('Partner contact0@example.test')
    expect(text(html)).toContain('contact37@example.test')
  })
})

describe('F12 labeled signature links', () => {
  // Revert-check: trailingSignatureLinkContact and per-line metadata in inlineHeaderLines/signatureLines.
  it.each(['paragraph', 'br', 'table'])('removes a signed %s block', (layout) => {
    const lines = ['The estimate is ready.', 'Best,', 'Jane Doe', email, phone]
    const html =
      layout === 'paragraph'
        ? paragraphs(lines)
        : layout === 'br'
          ? `<div>${lines.join('<br>')}</div>`
          : `<table><tr>${lines.map((line) => `<td>${line}</td>`).join('')}</tr></table>`
    expect(text(html)).toBe('The estimate is ready. Best, Jane Doe')
  })
  it('recognizes each anchor slice across br, nested text, and hidden descendants', () => {
    const contacts =
      '<a href="MAILTO:jane@example.test"><b>Email</b> me<br>Email <i>us</i><span hidden> tomorrow</span></a>'
    expect(text(signed([contacts]))).toBe('The estimate is ready. Best, Jane Doe')
  })
  it('recognizes formatting inside a label without changing shared text projection', () => {
    expect(
      text(signed(['<a href="mailto:jane@example.test">E<b>mail</b> <i>me</i></a>', phone])),
    ).toBe('The estimate is ready. Best, Jane Doe')
    expect(
      text(signed(['<a href="mailto:jane@example.test?subject=Estimate">Email me</a>', phone])),
    ).toBe('The estimate is ready. Best, Jane Doe')
  })
  it('uses links across blank separators and before a bounded metadata tail', () => {
    expect(text(signed([email, '', phone, 'License number: AB-1234']))).toBe(
      'The estimate is ready. Best, Jane Doe',
    )
  })
  it('counts a telephone link as non-email evidence for the existing weak-name policy', () => {
    expect(text(paragraphs(['The estimate is ready.', 'Jane Doe', email, phone]))).toBe(
      'The estimate is ready.',
    )
    expect(text(paragraphs(['The estimate is ready.', 'Jane Doe', email, email]))).toContain(
      'Email me Email me',
    )
  })
  it('allows a bare contact label and separator beside explicit links', () => {
    expect(text(signed([`Email: ${email}`, `Phone: ${phone}`]))).toBe(
      'The estimate is ready. Best, Jane Doe',
    )
  })
  it.each([
    '<a href="mailto:">Email me</a>',
    '<a href="mailto:invalid">Email me</a>',
    '<a href="mailto:.@example.test">Email me</a>',
    '<a href="mailto:a.@example.test">Email me</a>',
    '<a href="mailto:a..b@example.test">Email me</a>',
    '<a href="mailto:jane@example.test&#10;">Email me</a>',
    '<a href="tel:+14155551212&#10;">Call the office</a>',
    `Phone: ${email}`,
    `Email: ${phone}`,
    '<a href="mailto:?body=jane@example.test">Email me</a>',
    '<a href="mailto:jane@example.test extra">Email me</a>',
    '<a href="tel:">Call the office</a>',
    '<a href="tel:123">Call the office</a>',
    '<a href="tel:tomorrow">Call the office</a>',
    '<a href="https://example.test/report">Email me</a>',
    '<a href="xmailto:jane@example.test">Email me</a>',
    '<a href=" mailto:jane@example.test">Email me</a>',
    '<a href="mailto:jane@example.test">Call the office</a>',
    '<a href="tel:+14155551212">Email me</a>',
    '<a href="mailto:jane@example.test">Read the estimate</a>',
    '<a href="mailto:jane@example.test">Please email me if the estimate changes.</a>',
    `Please ${email} if the estimate changes.`,
    `${email} <a href="https://example.test/report">Read report</a>`,
    '<a href="mailto:jane@example.test" hidden>Email me</a>',
    '<a href="mailto:jane@example.test"><img src="https://example.test/icon.png"></a>',
    '<a href="mailto:jane@example.test">Email me<img src="https://example.test/icon.png"></a>',
  ])('preserves insufficient or unsafe contact evidence: %s', (line) => {
    expect(text(signed([line, phone]))).toContain('Jane Doe')
    expect(text(signed([line, phone]))).toContain('Call the office')
  })
  it('counts multiple links on one visible line only once', () => {
    expect(text(signed([`${email} | ${phone}`]))).toContain('Email me | Call the office')
    expect(text(signed([`${email} | ${phone}`, phone]))).toBe(
      'The estimate is ready. Best, Jane Doe',
    )
  })
  it('does not lend an adjacent br subline or cell its link target', () => {
    for (const contacts of [
      `<p>${email}<br>Call the office</p>`,
      `<table><tr><td>${email}</td><td>Call the office</td></tr></table>`,
      '<p><a href="mailto:jane@example.test">Email me<br>Please approve it.</a></p>',
    ]) {
      const html = paragraphs(['The estimate is ready.', 'Best,', 'Jane Doe']) + contacts
      expect(text(html)).toContain('Email me')
    }
  })
  it('preserves contact instructions, standalone links, postscripts, and contact lists', () => {
    for (const html of [
      paragraphs(['Please email these contacts:', 'Jane Doe', email, phone]),
      paragraphs(['The estimate is ready.', email]),
      signed([email, phone, 'P.S. The estimate changed.']),
      signed([email, phone, 'Thanks,', 'Kevin']),
    ]) {
      expect(text(html)).toContain('Email me')
    }
  })
  it.each([false, true])(
    'preserves repeated people with link-only contacts; closing: %s',
    (closing) => {
      const html =
        '<p>The team is listed below.</p><p>Best,</p><table>' +
        ['Jane Doe', 'John Smith']
          .map((name) => `<tr><td>${name}</td><td>${email}</td><td>${phone}</td></tr>`)
          .join('') +
        '</table>' +
        (closing ? '<p>Thanks,</p><p>Kevin</p>' : '')
      expect(text(html)).toContain('Jane Doe Email me Call the office John Smith')
      expect(removeQuotesFromHtml(html)).toContain('<table>')
    },
  )
  it('does not mistake contact labels for directory names in separate rows', () => {
    const html =
      '<p>The estimate is ready.</p><p>Best,</p><p>Jane Doe</p><table>' +
      ['<a href="mailto:jane@example.test">Email</a>', '<a href="tel:+14155551212">Telephone</a>']
        .map((line) => `<tr><td>${line}</td></tr>`)
        .join('') +
      '</table>'
    expect(text(html)).toBe('The estimate is ready. Best, Jane Doe')
  })
  it('preserves repeated directory records with names and contacts in br sublines', () => {
    const html =
      '<p>The team is listed below.</p><p>Best,</p><table>' +
      ['Jane Doe', 'John Smith']
        .map((name) => `<tr><td>${name}<br>Partner<br>${email}<br>${phone}</td></tr>`)
        .join('') +
      '</table>'
    expect(text(html)).toContain('Jane Doe Partner Email me Call the office John Smith')
    expect(removeQuotesFromHtml(html)).toContain('<table>')
  })
  it('preserves unmarked body media beside or after the signature', () => {
    const image = '<img src="https://example.test/diagram.png">'
    const beside = signed([email, `${phone}${image}`])
    expect(text(beside)).toContain('Email me')
    expect(removeQuotesFromHtml(beside)).toContain('diagram.png')
    const after = signed([email, phone]) + `<p>${image}</p>`
    expect(text(after)).toBe('The estimate is ready. Best, Jane Doe')
    expect(removeQuotesFromHtml(after)).toContain('diagram.png')
  })
})
