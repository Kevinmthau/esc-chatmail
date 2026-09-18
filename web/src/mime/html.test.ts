import { describe, expect, it } from 'vitest'
import corpusJson from '@fixtures/golden_message_corpus.json'
import { isStrongSignatureSupportLine, shouldPreserveSignatureNameLine } from './patterns'
import {
  isContactSignatureLine,
  isSignatureOwnedMedia,
  isTrailingSignatureContactLine,
  removeQuotesFromHtml,
} from './html'
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
      const wrapper = `<div class="gmail_signature">Best,<br>${name}<br>john@example.test<br>415-555-1212</div>`
      expect(cleanedText('<p>Current reply.</p>' + wrapper)).toBe('Current reply.')

      const heuristic = `<p>Best,</p><p>${name}</p><p>john@example.test</p><p>415-555-1212</p>`
      expect(cleanedText('<p>Current reply.</p>' + heuristic)).toBe('Current reply.\n\nBest,')
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

describe('Front core: bare hosts, owned media, wrapper name preservation, lead-in veto', () => {
  const corpusCase = (id: string): string => {
    const cases = (corpusJson as { htmlToBubbleTextCases: { id: string; inputHTML: string }[] })
      .htmlToBubbleTextCases
    const found = cases.find((scenario) => scenario.id === id)
    if (!found) throw new Error(`missing corpus case ${id}`)
    return found.inputHTML
  }

  // Revert-check: SIGNATURE_WRAPPER_SELECTORS 'div.front-signature' and
  // removeSignatureWrappers' name preservation after an outside sign-off. The corpus
  // replay pins the text; this pins that the wrapper route owns the logo and icon markup.
  it('removes the Front wrapper and keeps the name after the outside sign-off', () => {
    const html = corpusCase('html_front_signature_wrapper_short_reply_removed')
    const cleaned = removeQuotesFromHtml(html, 'quotedAndSignatures') ?? ''
    expect(cleanedText(html)).toBe(
      "Hi Jordan,\n\nJust so I'm clear, would you like me to go ahead and pay the balance?\n\nThanks so much,\n\nAvery Fenwick",
    )
    expect(cleaned).not.toContain('<table')
    expect(cleaned).not.toContain('front-blockquote')
  })

  // Revert-check: isSignatureOwnedMedia rules: aria-hidden, 1x1, width-only <= 48, sized
  // image-only social profile link <= 64 (never a post/video path, never unsized), sized
  // image-only https link with every declared side <= 100.
  it('owns icons, pixels and small linked logos only', () => {
    const html = `
      <div>
      <img id="pixel" src="https://t.example/p.gif" aria-hidden="true">
      <img id="onebyone" src="https://t.example/p.gif" width="1" height="1">
      <img id="widthonly" src="https://cdn.example/i.png" width="20">
      <img id="styled" src="https://cdn.example/i.png" style="width: 16px; height: 16px">
      <img id="tall" src="https://cdn.example/i.png" width="48" height="49">
      <img id="heightonly" src="https://cdn.example/i.png" height="20">
      <a href="https://www.linkedin.com/company/acme"><img id="social" src="https://cdn.example/in.png" width="24"></a>
      <a href="https://www.linkedin.com/in/janedoe"><img id="socialunsized" src="cid:screenshot"></a>
      <a href="https://www.linkedin.com/company/acme"><img id="socialwide" src="https://cdn.example/x.png" width="80"></a>
      <a href="https://www.linkedin.com/posts/acme_123"><img id="socialpost" src="cid:damage" width="600"></a>
      <a href="https://www.linkedin.com/posts/acme_123"><img id="socialpostsmall" src="https://cdn.example/p.png" width="80" height="80"></a>
      <a href="https://twitter.com/acme/status/1"><img id="tweet" src="cid:shot"></a>
      <a href="https://www.youtube.com/watch?v=1"><img id="video" src="cid:thumb" width="320" height="180"></a>
      <a href="https://www.youtube.com/watch?v=1"><img id="badge" src="https://cdn.example/yt.png" width="60" height="60"></a>
      <a href="https://signatures.example/acme"><img id="logo" src="https://cdn.example/logo.png" height="70"></a>
      <a href="https://docs.example/plan"><img id="photo" src="https://cdn.example/photo.jpg" width="1200" height="800"></a>
      <a href="https://docs.example/plan"><img id="undimensioned" src="https://cdn.example/photo.jpg"></a>
      <a href="https://twitter.com/acme">Follow us <img id="labeled" src="https://cdn.example/tw.png"></a>
      <picture id="picture"><img src="https://cdn.example/big.jpg" width="20" height="20"></picture>
      <img id="alt" src="cid:floorplan" alt="Company logo">
      </div>
    `
    const document = parseHtmlDocument(html)
    const owned = (id: string): boolean => {
      const element = document.getElementById(id)
      if (!element) throw new Error(`missing element ${id}`)
      return isSignatureOwnedMedia(element)
    }
    for (const id of ['pixel', 'onebyone', 'widthonly', 'styled', 'social', 'logo', 'badge']) {
      expect(owned(id), id).toBe(true)
    }
    for (const id of [
      'tall',
      'heightonly',
      'socialunsized',
      'socialwide',
      'socialpost',
      'socialpostsmall',
      'tweet',
      'video',
      'photo',
      'undimensioned',
      'labeled',
      'picture',
      'alt',
    ]) {
      expect(owned(id), id).toBe(false)
    }
  })

  // Revert-check: isSignatureOwnedMedia inside containsSignatureTailMedia.
  it('removes an inferred signature block with trailing social icons', () => {
    const html =
      '<div>Current reply.</div>' +
      '<div>Best,<br>Jane Doe<br>Partner<br><a href="mailto:jane@example.test">jane@example.test</a><br>415-555-1212<br>' +
      '<a href="https://www.linkedin.com/company/acme"><img src="https://cdn.example/in.png" width="20" height="20" alt="-"></a>&nbsp;' +
      '<a href="https://twitter.com/acme"><img src="https://cdn.example/tw.png" width="20" height="20" alt="-"></a></div>'
    const cleaned = removeQuotesFromHtml(html, 'quotedAndSignatures') ?? ''
    expect(cleanedText(html)).toBe('Current reply.\n\nBest,\nJane Doe')
    expect(cleaned).not.toContain('<img')
  })

  // HONEST SCOPE: passes at HEAD. A dimensioned screenshot linked to a tweet is authored media:
  // it stays, and so does the media-before-signature prefix handling that keeps it in place. The
  // guard this pins is that isSignatureOwnedMedia's social rule never owns a content-path link.
  it('preserves a social-linked screenshot before the sign-off', () => {
    const html =
      '<div>Look at this.<br><a href="https://twitter.com/acme/status/123"><img src="cid:shot" width="600" height="400"></a><br>' +
      'Best,<br>Jane Doe<br>Partner<br><a href="mailto:jane@example.test">jane@example.test</a><br>415-555-1212</div>'
    const cleaned = removeQuotesFromHtml(html, 'quotedAndSignatures') ?? ''
    expect(cleaned).toContain('cid:shot')
    expect(cleanedText(html)).toBe('Look at this.\n\nBest,\nJane Doe')
  })

  // Revert-check: BARE_HOST_LINE_PATTERN allowlist (every label two characters, explicit TLDs).
  it.each([
    'acmeadvisory.com',
    'www.nordvik.no',
    'nordvik.no',
    'Web: acme.co.uk',
    'acme.io/',
    'logo.ai',
    'NORDVIK.NO',
  ])('treats a bare host row as a contact line: %s', (host) => {
    expect(isTrailingSignatureContactLine(host)).toBe(true)
    expect(isContactSignatureLine(host)).toBe(true)
  })

  // HONEST SCOPE: passes at HEAD for every rejected input; pins the bare-host allowlist's rejections.
  it.each([
    'main.cc',
    'README.md',
    'script.py',
    'photos.heic',
    'video.mov',
    'M.Sc',
    'e.g.',
    'Ph.D.',
    'acme.com is down',
    'See acme.com',
    'Nordvik AS',
    'a.co',
    'acme.com.',
  ])('does not treat a filename, abbreviation or prose mention as a host: %s', (notHost) => {
    expect(isTrailingSignatureContactLine(notHost)).toBe(false)
  })

  // Revert-check: the lowercase multi-word tail guard in isLikelyCombinedSignOffAndNameLine. "Best
  // of luck," is a closing sentence, not "Best" plus a person called "of luck"; without a
  // recognised closing the whole wrapper goes, instead of keeping the closing and dropping the
  // name. Caseless scripts and a lone lowercase name carry no such signal and stay preserved.
  it('requires a capitalized name after a combined sign-off in a wrapper', () => {
    const html =
      '<p>Body.</p><div class="gmail_signature">Best of luck,<br>Avery Fenwick<br>415-555-1212</div>'
    expect(cleanedText(html)).toBe('Body.')

    for (const kept of ['Regards, 田中', 'cheers, kevin']) {
      const wrapper = `<p>Body.</p><div class="gmail_signature">${kept}<br>Partner<br>415-555-1212</div>`
      expect(cleanedText(wrapper), kept).toBe(`Body.\n\n${kept}`)
    }

    const combined =
      '<p>Body.</p><div class="gmail_signature">Thanks so much, Avery Fenwick<br>Partner<br>415-555-1212</div>'
    expect(cleanedText(combined)).toBe('Body.\n\nThanks so much, Avery Fenwick')
  })

  // Revert-check: isAuthoredLeadInLine replaces the keyword-only intro check; a colon lead-in
  // with no contact keyword and a strong title below it was removed before.
  it('preserves a referral card introduced by a colon lead-in', () => {
    const html =
      '<div>You can reach the plumber here:</div><div>Jane Doe</div><div>Account Manager</div><div>Acme Plumbing</div>' +
      '<div><a href="mailto:jane@acmeplumbing.test">jane@acmeplumbing.test</a></div><div>404-555-0142</div>'
    const originalText = (source: string): string =>
      paragraphAwareText(parseHtmlDocument(source).body).trim()
    expect(cleanedText(html)).toBe(originalText(html))
    const keyworded = html.replace(
      'You can reach the plumber here:',
      'Here are the reviewer contacts:',
    )
    expect(cleanedText(keyworded)).toBe(originalText(keyworded))
  })

  // Revert-check: BARE_HOST_LINE_PATTERN (the scan stops at "acmeadvisory.com" without it),
  // SIGN_OFF_PHRASES 'thanks so much' (nothing anchors the pair without it), and
  // isSignatureOwnedMedia (the logo cell inside the widened range vetoes removal without it).
  // Each alone leaves the card in the bubble.
  it('removes the token-free Front shape through the heuristic route', () => {
    const html = corpusCase('html_thanks_so_much_signoff_logo_between_name_preserved')
    const text = cleanedText(html)
    // The heuristic route re-emits the pair as one <div> with a <br>; the bubble pipeline's
    // unwrap turns that into the same two-paragraph text the wrapper route produces.
    expect(text).toBe(
      "Hi Jordan,\n\nJust so I'm clear, would you like me to go ahead and pay the balance?\n\nThanks so much,\nAvery Fenwick",
    )
    for (const removed of [
      'Associate Relationship Manager',
      'acmeadvisory.com',
      'Direct:',
      'Los Angeles',
    ]) {
      expect(text, removed).not.toContain(removed)
    }
  })

  // Revert-check: the bareHostContactLineCount guard in truncateTrailingContactSignature.
  // Extensions that double as country codes ("Logo.ai", "main.tf") match BARE_HOST_LINE_PATTERN,
  // so a bare host may corroborate a block that has a real contact row but never anchor one by
  // itself.
  it('does not read a file list after the sign-off as a contact block', () => {
    const files =
      '<div>Attached are the two files.</div><div>Best,</div><div>Jane</div><div><br></div><div>Brand.ai</div><div>Logo.ai</div><div>Main.tf</div>'
    expect(cleanedText(files)).toBe(paragraphAwareText(parseHtmlDocument(files).body).trim())

    const anchored =
      '<div>Attached are the two files.</div><div>Best,</div><div>Jane Doe</div>' +
      '<div><a href="mailto:jane@brand.ai">jane@brand.ai</a></div><div>Brand.ai</div>'
    expect(cleanedText(anchored)).toBe('Attached are the two files.\n\nBest,\nJane Doe')
  })

  // Revert-check: truncateTrailingContactSignature only hoists signatureStart onto the
  // sign-off when the following name is actually re-emitted.
  it('keeps an unpaired gratitude closing above a pipe-title signature', () => {
    const pipe =
      '<div>Hi Bob,</div><div>Thank you so much!</div><div>Jane Doe | Director of Sales</div>' +
      '<div>Acme Inc.</div><div>415-555-1234</div><div><a href="mailto:jane@acme.com">jane@acme.com</a></div>'
    expect(cleanedText(pipe)).toBe('Hi Bob,\n\nThank you so much!')

    const gratitudeOnly =
      '<div>Thank you so much!</div><div>Jane Doe | Director of Sales</div>' +
      '<div>Acme Inc.</div><div>415-555-1234</div><div><a href="mailto:jane@acme.com">jane@acme.com</a></div>'
    expect(cleanedText(gratitudeOnly)).toBe('Thank you so much!')

    const companyFirst =
      '<div>Received, I will process the payment today.</div><div>Thank you very much.</div>' +
      '<div>Acme Plumbing LLC</div><div>555-123-4567</div>' +
      '<div><a href="mailto:info@acmeplumbing.com">info@acmeplumbing.com</a></div>'
    expect(cleanedText(companyFirst)).toBe(
      'Received, I will process the payment today.\n\nThank you very much.',
    )

    const sharedBlock =
      '<div>Hi Bob,</div><div>Thank you so much!<br>Jane Doe | Director of Sales<br>Acme Inc.' +
      '<br>415-555-1234<br><a href="mailto:jane@acme.com">jane@acme.com</a></div>'
    expect(cleanedText(sharedBlock)).toBe('Hi Bob,\n\nThank you so much!')
  })

  // Revert-check: 'div.gmail_signature_prefix' ordered before 'div.gmail_signature' in
  // SIGNATURE_WRAPPER_SELECTORS, so the wrapper's previous visible line is the sign-off, not "--".
  it('does not let the Gmail "--" prefix hide the outside sign-off from name preservation', () => {
    const html =
      '<div>Sounds good.</div><div>Thanks,</div><div class="gmail_signature_prefix">-- </div>' +
      '<div class="gmail_signature"><div>Jane Doe</div><div>CEO</div><div><a href="mailto:jane@example.test">jane@example.test</a></div></div>'
    expect(cleanedText(html)).toBe('Sounds good.\n\nThanks,\n\nJane Doe')
  })
})
