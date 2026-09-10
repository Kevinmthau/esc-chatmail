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
    'Emergency line: 555-1212 x112',
    'Toll-free number: +1 800-555-1212',

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
    'Do not pay the consultant',
    'DO NOT PAY THE CONSULTANT',
    'PLEASE CHECK WITH YOUR ATTORNEY',
    'DO NOT PAY THE CONSULTANT UNTIL APPROVED',
    'ATTORNEY APPROVAL IS REQUIRED BEFORE PAYMENT',
    'Consultant Approval Required Before You Pay',
    'STOP WORK UNTIL COUNSEL REVIEWS',
    'HOLD FUNDS UNTIL ATTORNEY CONFIRMS',
    'ESCALATE THIS TO THE ATTORNEY',
    'Hold Funds Until Attorney Confirms',
    'COMPANY CLOSED UNTIL FURTHER NOTICE',
    'Company Closed Until Further Notice',
    'GROUP DISCOUNTS AVAILABLE THROUGH FRIDAY',
    'Please check with your attorney',
    'I will check with counsel',
    'We need a new engineer',
    'The analyst will follow up',
    'Payment pending attorney approval',
    'Approval pending from counsel',
    'Service period: 2026-2027',
    'Service date: 2026-0815',
    'Office hours: 0900-1700',
    'Phone model: 1234-5678',
    'Emergency line: 08-15-2026 (office)',
    'Emergency line: 2026-0815',
    'After hours: 0900-1700',
    'After hours: 09.00-17.00',
    'After hours: 9.00-17.00',
    'After hours: 0900-2400',
    'Emergency line: 08 - 15 - 2026',
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
    'Service period: 2026-2027',
    'Service date: 2026-0815',
    'Office hours: 0900-1700',
    'Phone model: 1234-5678',
    'Emergency line: 08-15-2026 (office)',
    'Emergency line: 2026-0815',
    'After hours: 0900-1700',
    'After hours: 09.00-17.00',
    'After hours: 9.00-17.00',
    'After hours: 0900-2400',
    'Emergency line: 08 - 15 - 2026',
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
      'Director of Sales',
      'consultant',
      'Senior Financial Analyst',
      'software engineer',
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
  // Remove only recognized metadata after a confirmed contact block.
  it.each([
    'NPN 1234567',
    'License number: AB-1234',
    'Registration #12345',
    'Licensed in GA, AL and TN - NPN 1234567',
  ])('removes a bounded tail: %s', (tail) => {
    const html = messageWithTrailingSignature('') + `<p>${tail}</p><p><img src="cid:badge"></p>`
    expect(cleanedText(html)).toBe('Current reply.')
    expect(removeQuotesFromHtml(html)).toContain('cid:badge')
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
it.each([
  'P.S. Bring the draft.',
  'Please bring the draft.',
  'The estimate changed.',
  'Do not send the money.',
  'Deadline moved to Friday.',
  'Licensed driver needed for 2 days.',
  'Registration closes on September 15; send the application by then.',
  'Approve payment | Sign contract | Request changes',
  'Protecting what matters most.',
  'Auto | Home | Life | Business',
])('preserves a post-signature instruction: %s', (tail) => {
  expect(cleanedText(messageWithTrailingSignature('') + `<p>${tail}</p>`)).toContain(tail)
})

// Authored legal discussion and body images must survive signature cleanup.
it.each([
  'Disclaimer: figures are provisional.',
  'This email may contain errors.',
  'This email and any attachments need your approval.',
  'Confidentiality notice: can we remove this from the template?',
])('preserves an authored paragraph starting with %s', (line) => {
  const html = `<p>Here are my concerns.</p><p>${line}</p><p>Do not approve yet.</p>`
  expect(cleanedText(html)).toBe(`Here are my concerns.\n\n${line}\n\nDo not approve yet.`)
})

it('preserves an authored image after a contact signature', () => {
  const html =
    messageWithTrailingSignature('') +
    '<section>These are the latest pictures.</section><p><img src="cid:damage" width="1600" height="1200" alt="Cracked pipe"></p>'
  expect(removeQuotesFromHtml(html)).toContain('cid:damage')
  expect(cleanedText(html)).toContain('These are the latest pictures.')
})

it('removes an unidentified logo inside an explicit signature wrapper', () => {
  const html =
    '<p>Current reply.</p><div class="gmail_signature"><p>Jane Doe</p><p>Partner</p><p>jane@example.test</p><p>415-555-1212</p><p><img src="cid:arbitrary"></p></div>'
  expect(removeQuotesFromHtml(html)).not.toContain('cid:arbitrary')
  expect(cleanedText(html)).toBe('Current reply.')
})

it('requires signature context and preserves the original in quoted-only mode', () => {
  const footer =
    '<p>CONFIDENTIALITY NOTICE: This e-mail and any attachments are for the exclusive use of the intended recipient.</p>'
  const body = '<p>Here is the proposed template.</p>' + footer
  expect(cleanedText(body)).toContain('CONFIDENTIALITY NOTICE:')
  const signed = messageWithTrailingSignature('') + footer
  expect(removeQuotesFromHtml(signed, 'quotedOnly')).toContain('john@example.test')
  expect(removeQuotesFromHtml(signed, 'quotedOnly')).toContain('CONFIDENTIALITY NOTICE:')
  expect(cleanedText(signed + '<p>Do not approve yet.</p>')).toContain('Do not approve yet.')
})

it('bounds the metadata tail scan to three lines', () => {
  const signature = messageWithTrailingSignature('')
  const tail = '<p>NPN 1234567</p>'
  expect(cleanedText(signature + tail.repeat(3))).toBe('Current reply.')
  expect(cleanedText(signature + tail.repeat(4))).toContain('john@example.test')
})

it.each([
  '<p><img src="cid:damage"></p><p>NPN 1234567</p>',
  '<p><a href="cid:damage">License #AB-1234</a></p>',
  '<p><a xlink:href="cid:damage">License #AB-1234</a></p>',
  '<div style="background-image:url(cid:damage);width:1200px;height:800px"></div><p>NPN 1234567</p>',
  '<p>NPN 1234567<span style="background-image:url(cid:damage)"></span></p>',
  '<div background="cid:damage"></div><p>NPN 1234567</p>',
  '<p>NPN 1234567<img src="cid:damage"></p>',
  '<p><img src="cid:damage"></p><p>CONFIDENTIALITY NOTICE: This e-mail and any attachments are for the exclusive use of the intended recipient.</p>',
  '<p>CONFIDENTIALITY NOTICE: This e-mail and any attachments are for the exclusive use of the intended recipient.<img src="cid:damage"></p>',
])('preserves body media within the expanded signature range: %s', (tail) => {
  expect(removeQuotesFromHtml(messageWithTrailingSignature('') + tail)).toContain('cid:damage')
})

it.each([
  'CONFIDENTIALITY NOTICE: This e-mail and any attachments are for the exclusive use of the intended recipient.<br><br>P.S. Do not send the money.',
  'Confidentiality notice: remove the intended recipient clause and the word confidential.',
])('preserves authored content in a legal-looking tail: %s', (tail) => {
  const result = cleanedText(messageWithTrailingSignature('') + `<p>${tail}</p>`)
  expect(result).toContain('john@example.test')
  expect(result).toContain(tail.includes('P.S.') ? 'P.S. Do not send the money.' : tail)
})

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
    // Leading media has no reliable signature ownership; retain it during inferred cleanup.
    expect(removeQuotesFromHtml(html)?.includes('cid:badge')).toBe(html.includes('cid:badge'))
  })
  it.each(['<img src="cid:floorplan">', '<svg><image href="cid:floorplan"></image></svg>'])(
    'preserves leading media before an inferred signature: %s',
    (media) => {
      for (const block of [
        `<div>${media}<br>${contact}</div>`,
        `<div>${media}${contact}</div>`,
        `<table><tr><td>${media}<br>${contact}</td></tr></table>`,
        `<table><tr><td>${media}</td><td>${contact}</td></tr></table>`,
      ]) {
        const html = '<p>The floorplan is attached below.</p>' + block
        const cleaned = removeQuotesFromHtml(html)
        expect(cleaned).toContain('cid:floorplan')
        expect(cleaned).not.toContain('john@example.test')
        expect(cleanedText(html)).toContain('John Smith')
      }
    },
  )
  it.each([
    '<div>Current reply.<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212<br><img src="cid:damage"></div>',
    '<table><tr><td>Current reply.<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212<br><img src="cid:damage"></td></tr></table>',
    '<table><tr><td>Current reply.<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212</td><td><img src="cid:damage"></td></tr></table>',
  ])('preserves trailing media inside a shared signature block: %s', (html) => {
    expect(removeQuotesFromHtml(html)).toContain('cid:damage')
    expect(cleanedText(html)).toContain('Current reply.')
  })
  it.each([
    '<div><a href="cid:damage">John Smith</a><br>Partner<br>john@example.test<br>415-555-1212</div>',
    '<div><a xlink:href="cid:damage">John Smith</a><br>Partner<br>john@example.test<br>415-555-1212</div>',
    '<div style="background-image:url (cid:damage)">John Smith<br>Partner<br>john@example.test<br>415-555-1212</div>',
    '<div><span style="background-image:url (cid:damage)">John Smith</span><br>Partner<br>john@example.test<br>415-555-1212</div>',
  ])('preserves media on a signature boundary ancestor: %s', (block) => {
    const html = '<p>Current reply.</p>' + block
    expect(removeQuotesFromHtml(html)).toContain('cid:damage')
    expect(cleanedText(html)).toContain('Current reply.')
  })
  it.each(['href', 'xlink:href'])(
    'preserves a leading CID link before an inferred signature: %s',
    (attribute) => {
      const html = `<p>Current reply.</p><div><a ${attribute}="cid:damage"></a><br>${contact}</div>`
      expect(removeQuotesFromHtml(html)).toContain('cid:damage')
      expect(removeQuotesFromHtml(html)).not.toContain('john@example.test')
      expect(cleanedText(html)).toContain('John Smith')
    },
  )
  it.each(['text', 'title'])('does not truncate inside diagram %s', (tag) => {
    const html =
      '<p>The floorplan is below.</p>' +
      `<div><svg><${tag}>Floorplan</${tag}><rect width="200" height="200"></rect></svg><br>John Smith<br>Partner<br>john@example.test<br>415-555-1212</div>`
    const cleaned = removeQuotesFromHtml(html)
    expect(cleaned).toContain('Floorplan')
    expect(cleaned).toContain('<rect')
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
  it('preserves an authored heading and product list before a signature', () => {
    const html =
      '<p>Current reply.</p><p>Available Options</p><p>Basic | Pro | Enterprise</p>' +
      '<p>John Smith</p><p>Partner</p><p>john@example.test</p><p>415-555-1212</p>'
    const result = cleanedText(html)
    expect(result).toContain('Available Options')
    expect(result).toContain('Basic | Pro | Enterprise')
    expect(result).not.toContain('john@example.test')
  })
  it.each([
    'Please send the signed document to legal@example.test before Friday.',
    'Please upload the signed document to https://example.test/upload before Friday.',
    'Please meet us on Market Street.',
    'Send to legal@example.test.',
  ])('preserves an authored instruction before a BR signature: %s', (instruction) => {
    const html = `<div>Current reply.<br>${instruction}<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212</div>`
    const result = cleanedText(html)
    expect(result).toContain(instruction)
    expect(result).not.toContain('john@example.test')
    const withPostscript = `<div>Current reply.<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212<br>${instruction}</div>`
    expect(cleanedText(withPostscript)).toContain(instruction)
  })
  it('preserves a contact table with column headings', () => {
    for (const tag of ['th', 'td']) {
      const html =
        '<p>Please use the person listed below to arrange the repairs.</p>' +
        `<table><tr><${tag}>Engineer</${tag}><${tag}>Role</${tag}><${tag}>Email</${tag}><${tag}>Phone</${tag}></tr>` +
        '<tr><td>John Smith</td><td>Partner</td><td>john@example.test</td><td>415-555-1212</td></tr></table>'
      const result = cleanedText(html)
      expect(result).toContain('John Smith')
      expect(result).toContain('Partner')
      expect(result).toContain('john@example.test')
      expect(result).toContain('415-555-1212')
    }
  })
  it('preserves multiple person records in a table without headings', () => {
    const html =
      '<p>Use these people.</p><table>' +
      '<tr><td>John Smith</td><td>Partner</td><td>john@example.test</td><td>415-555-1212</td></tr>' +
      '<tr><td>Jane Brown</td><td>Partner</td><td>jane@example.test</td><td>212-555-1212</td></tr></table>'
    const result = cleanedText(html)
    expect(result).toContain('John Smith')
    expect(result).toContain('john@example.test')
    expect(result).toContain('Jane Brown')
    expect(result).toContain('jane@example.test')
  })
  it('requires stronger evidence for a single contact record spread across cells', () => {
    const html =
      '<p>Please use the person listed below to arrange the repairs.</p>' +
      '<table><tr><td>John Smith</td><td>john@example.test</td><td>415-555-1212</td></tr></table>'
    const result = cleanedText(html)
    expect(result).toContain('John Smith')
    expect(result).toContain('john@example.test')
    expect(result).toContain('415-555-1212')
  })
  it.each([
    '<tr><td>John Smith</td><td>Partner</td><td>john@example.test</td><td>415-555-1212</td></tr>',
    '<tr><td>John Smith<br>john@example.test<br>415-555-1212</td></tr>',
    '<tr><td><img src="cid:badge"></td><td>John Smith<br>john@example.test<br>415-555-1212</td></tr>',
  ])('still removes a confirmed signature table: %s', (rows) => {
    expect(cleanedText(`<p>Current reply.</p><table>${rows}</table>`)).toBe('Current reply.')
  })
  it('preserves a personal sign-off when a horizontal signature has no title', () => {
    const html =
      '<p>Current reply.</p><table><tr><td>Best,</td><td>John Smith</td>' +
      '<td>john@example.test</td><td>415-555-1212</td></tr></table>'
    const result = cleanedText(html)
    expect(result).toContain('Current reply.')
    expect(result).toContain('Best,')
    expect(result).toContain('John Smith')
    expect(result).not.toContain('john@example.test')
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

it('preserves all unmarked trailing images when cutting inside a shared block', () => {
  // Revert-check: text-node truncation stops at the owner block rather than deleting later images.
  const html =
    '<div>Current reply.<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212</div>' +
    [1, 2, 3, 4].map((n) => `<p><img src="cid:photo${n}"></p>`).join('')
  const cleaned = removeQuotesFromHtml(html)
  for (const index of [1, 2, 3, 4]) {
    expect(cleaned).toContain(`cid:photo${index}`)
  }
  expect(cleaned).not.toContain('john@example.test')
})
