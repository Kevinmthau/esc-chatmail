// Port of RepeatedCorporateSignatureTests.swift and its fixture
// (RepeatedCorporateSignatureFixture.swift): a synthetic Outlook reply with a
// long, repeated corporate signature. Names, contact details, message text and
// reference values are invented.
import { describe, expect, it } from 'vitest'
import { htmlCompatibilityFallback, plainTextOnlyFallback, processChatBubbleText } from './bubble'
import { removeQuotesFromHtml } from './html'
import { extractPlainTextFromHtml } from './htmlText'
import { removeRepeatedSignature } from './repeatedSignature'
import { extractQuotes } from './text'

type Footer = 'coverage' | 'operations'

const bodyParagraphs = [
  'Hi Avery,',
  'The reviewer confirmed that the report contained an unrelated entry, so it has been removed from the revised proposal. The updated proposal is now ready for your review.',
  'I have attached the revised documents. Please confirm whether you would like us to proceed with the requested change.',
  'We will also remove the old item from your account.',
  'Thank you!',
]
const signOff = 'Sincerely,'
const senderName = 'Taylor Morgan'
const priorReply = 'I will check the report and send an update once the reviewer responds.'
const expectedChatText = [...bodyParagraphs, signOff, senderName].join('\n\n')
const newPostscript = 'P.S. Please wait until Monday before making the requested change.'
const oldPostscript = 'P.S. Please use the earlier draft when reviewing the requested change.'

const contactLines = [
  'Senior Account Manager | CA License #0A00000',
  'Personal Lines',
  'West Division',
  'CA Agency License: 0B00000',
  '100 Example Blvd., Floor 2',
  'Sample City, CA 90000',
  'Direct: 202-555-0101',
  'Fax: 202-555-0102',
  'Email: taylor@example.test',
  'Bill Pay Online: billing.example.test',
]

function footerParagraphs(footer: Footer): string[] {
  switch (footer) {
    case 'coverage':
      return [
        '***Changes in payment reminders for our customers***',
        'Our team previously sent individual reminders when a payment was approaching. Beginning this month, customers should consult their statements for the payment schedule. Please arrange each payment before its due date so your selected services remain active.',
        'Coverage requests require written confirmation from an authorized representative of Example Services or the applicable provider before they take effect. Please contact your representative if you have questions about an existing request.',
      ]
    case 'operations':
      return [
        '***Equipment collection arrangements for visitors***',
        'Our workshop prepares each reserved collection before the scheduled visit. Visitors should use the east entrance and check the collection board when they arrive. Please bring a copy of the reservation so the workshop team can locate the prepared equipment.',
        'Collection arrangements are recorded in the workshop schedule after a coordinator has reviewed the request. If the loading area is occupied, please wait in the marked visitor space until the coordinator confirms that your equipment is ready.',
      ]
  }
}

interface FixtureOptions {
  footer?: Footer
  includeHistory?: boolean
  currentPostscript?: string
  historicalPostscript?: string
  historicalFooter?: Footer
}

function plainSignature(footer: Footer, linkedContactDetails = false): string {
  const contacts = contactLines.map((line) => {
    if (!linkedContactDetails) return line
    if (line.startsWith('Email:')) return line + '<mailto:taylor@example.test>'
    if (line.startsWith('Direct:')) return line + '<tel:2025550101>'
    if (line.startsWith('Fax:')) return line + '<tel:2025550102>'
    if (line.startsWith('Bill Pay')) return line + '<http://billing.example.test>'
    if (line.startsWith('100 Example')) return line + '<https://maps.example.test/office>'
    return line
  })
  const footerText = footerParagraphs(footer)
  return (
    [signOff, senderName, ...contacts].join('\n') +
    '\n\n' +
    footerText.slice(0, 2).join('\n') +
    '\n\n[Example Services logo]\n' +
    footerText[2]!
  )
}

function fixturePlainText({
  footer = 'coverage',
  includeHistory = true,
  currentPostscript,
  historicalPostscript,
  historicalFooter,
}: FixtureOptions = {}): string {
  const current = [
    ...bodyParagraphs,
    plainSignature(footer),
    ...(currentPostscript === undefined ? [] : [currentPostscript]),
  ].join('\r\n\r\n')
  if (!includeHistory) return current

  const history = [
    'From: Avery Parker <avery@example.test>',
    'Sent: Thursday, August 20, 2026 10:00 AM',
    'To: Taylor Morgan <taylor@example.test>',
    'Subject: Re: Account update',
    '',
    'Thanks for checking.',
    '',
    'On Thu, Aug 20, 2026 at 9:00 AM Taylor Morgan <taylor@example.test> wrote:',
    priorReply,
    '',
    plainSignature(historicalFooter ?? footer, true),
    historicalPostscript === undefined ? '' : '\n\n' + historicalPostscript,
  ]
    .join('\n')
    .replace(/\n/g, '\r\n')
  return current + '\r\n\r\n' + history
}

function paragraphs(lines: string[]): string {
  return lines.map((line) => `<p class="MsoNormal">${line}<o:p></o:p></p>`).join('\n')
}

function htmlSignature(footer: Footer, linkedContactDetails = false): string {
  const contacts = contactLines
    .map((line) => {
      if (line.startsWith('Email:')) {
        return 'Email: <a href="mailto:taylor@example.test">taylor@example.test</a>'
      }
      if (linkedContactDetails && line.startsWith('Bill Pay')) {
        return 'Bill Pay Online: <a href="http://billing.example.test">billing.example.test</a>'
      }
      if (linkedContactDetails && line.startsWith('Direct:')) {
        return 'Direct: <a href="tel:2025550101">202-555-0101</a>'
      }
      if (linkedContactDetails && line.startsWith('100 Example')) {
        return `<a href="https://maps.example.test/office">${line}</a>`
      }
      return line
    })
    .join('<br>\n')
  const footerText = footerParagraphs(footer)
  return `<p class="MsoNormal"><o:p>&nbsp;</o:p></p>
<p class="MsoNormal" style="line-height:15.0pt"><b><span style="font-size:14pt">${signOff}</span></b></p>
<p class="MsoNormal" style="margin-bottom:6pt"><b><span style="font-size:10.5pt">${senderName}<br></span></b>
  <span style="font-size:9pt">${contacts}<o:p></o:p></span></p>
<p class="MsoNormal" style="margin-bottom:6pt"><b><span style="font-size:9pt;color:#3399FF">
  ${footerText[0]!}<br>${footerText[1]!}<br></span></b><br>
  <img width="229" height="27" src="cid:example-logo.png" alt="Example Services logo"></p>
${paragraphs([footerText[2]!])}`
}

function fixtureHtml({
  footer = 'coverage',
  includeHistory = true,
  currentPostscript,
  historicalPostscript,
  historicalFooter,
}: FixtureOptions = {}): string {
  const current =
    paragraphs(bodyParagraphs) +
    htmlSignature(footer) +
    (currentPostscript === undefined ? '' : paragraphs([currentPostscript]))
  const history = includeHistory
    ? `<div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in">
  <p class="MsoNormal"><b>From:</b> Avery Parker &lt;avery@example.test&gt;<br>
  <b>Sent:</b> Thursday, August 20, 2026 10:00 AM<br>
  <b>To:</b> Taylor Morgan &lt;taylor@example.test&gt;<br>
  <b>Subject:</b> Re: Account update</p>
</div>
<p class="MsoNormal">Thanks for checking.</p>
<div class="gmail_quote">
  <div>On Thu, Aug 20, 2026 at 9:00 AM Taylor Morgan &lt;taylor@example.test&gt; wrote:</div>
  <blockquote style="border-left:solid #cccccc 1.0pt;padding-left:6.0pt">
    ${paragraphs([priorReply])}
    ${htmlSignature(historicalFooter ?? footer, true)}
    ${historicalPostscript === undefined ? '' : paragraphs([historicalPostscript])}
  </blockquote>
</div>`
    : ''

  return `<html xmlns:o="urn:schemas-microsoft-com:office:office">
<head><meta name="Generator" content="Microsoft Word 15 (filtered medium)">
<style>p.MsoNormal { margin:0in; font-size:12pt; font-family:Aptos,sans-serif; }</style></head>
<body><div class="WordSection1">${current}${history}</div></body>
</html>`
}

function htmlPreview(html: string) {
  return htmlCompatibilityFallback(html, true)
}

function plainPreview(text: string) {
  return plainTextOnlyFallback(text)
}

function normalized(text: string | null | undefined): string {
  return (text ?? '')
    .split(/\s+/)
    .filter((word) => word.length > 0)
    .join(' ')
}

describe('repeated corporate signature', () => {
  // Revert-check: removeRepeatedSignature call in bubble.ts processHtml
  it('Outlook HTML, repeated corporate footer, leaves the reply and sign-off', () => {
    const result = htmlPreview(fixtureHtml())

    expect(normalized(result.mainText)).toBe(normalized(expectedChatText))
    expect(result.hasRichContent).toBe(false)
    expect(result.quotedParts).toEqual([])
  })

  // Revert-check: removeRepeatedSignature call in text.ts extractQuotes
  it('plain text, repeated corporate footer, leaves the reply and sign-off', () => {
    const result = plainPreview(fixturePlainText())

    expect(normalized(result.mainText)).toBe(normalized(expectedChatText))
    expect(result.hasRichContent).toBe(false)
    expect(result.mainText).not.toContain(priorReply)
  })

  // Revert-check: removeRepeatedSignature (repeatedSignature.ts)
  it('unknown repeated boilerplate, is removed without industry-specific phrases', () => {
    const results = [
      htmlPreview(fixtureHtml({ footer: 'operations' })),
      plainPreview(fixturePlainText({ footer: 'operations' })),
    ]

    for (const result of results) {
      expect(normalized(result.mainText)).toBe(normalized(expectedChatText))
    }
  })

  // Revert-check: the whole-word history match in removeRepeatedSignature —
  // the block from the sign-off through the new postscript never repeats in
  // history, so the match declines before the postscript veto is consulted.
  // HONEST SCOPE: survives a revert of the postscript veto alone; the
  // 'repeated postscript, remains authored content' case below pins the veto.
  it('new postscript after a repeated footer, is preserved', () => {
    const results = [
      htmlPreview(fixtureHtml({ currentPostscript: newPostscript })),
      plainPreview(fixturePlainText({ currentPostscript: newPostscript })),
    ]

    for (const result of results) {
      expect(result.mainText).toContain(newPostscript)
      expect(result.mainText).toContain(bodyParagraphs[1]!)
      expect(result.mainText).not.toContain(priorReply)
    }
  })

  it('changed postscript after a repeated footer, preserves the current version', () => {
    const results = [
      htmlPreview(
        fixtureHtml({ currentPostscript: newPostscript, historicalPostscript: oldPostscript }),
      ),
      plainPreview(
        fixturePlainText({ currentPostscript: newPostscript, historicalPostscript: oldPostscript }),
      ),
    ]

    for (const result of results) {
      expect(result.mainText).toContain(newPostscript)
      expect(result.mainText).not.toContain(oldPostscript)
    }
  })

  // Revert-check: the whole-word history match in removeRepeatedSignature
  it('unknown footer without a historical match, is preserved', () => {
    const footer = footerParagraphs('operations')
    const results = [
      htmlPreview(fixtureHtml({ footer: 'operations', includeHistory: false })),
      plainPreview(fixturePlainText({ footer: 'operations', includeHistory: false })),
    ]

    for (const result of results) {
      for (const paragraph of footer) {
        expect(normalized(result.mainText)).toContain(normalized(paragraph))
      }
    }
  })

  // Revert-check: the whole-word history match in removeRepeatedSignature
  it('different historical footer, does not authorize removing the current prose', () => {
    const results = [
      htmlPreview(fixtureHtml({ footer: 'operations', historicalFooter: 'coverage' })),
      plainPreview(fixturePlainText({ footer: 'operations', historicalFooter: 'coverage' })),
    ]

    for (const result of results) {
      for (const paragraph of footerParagraphs('operations')) {
        expect(normalized(result.mainText)).toContain(normalized(paragraph))
      }
      expect(result.mainText).not.toContain(priorReply)
    }
  })

  // HONEST SCOPE: pins that the evidence pass reads history without mutating the
  // quote-only HTML cleanup; it survives a revert of removeRepeatedSignature.
  it('quote-only HTML cleanup, keeps the current signature and footer', () => {
    const cleaned = removeQuotesFromHtml(fixtureHtml(), 'quotedOnly')
    expect(cleaned).not.toBeNull()
    const visibleText = normalized(extractPlainTextFromHtml(cleaned!))

    expect(visibleText).toContain(contactLines[0]!)
    for (const paragraph of footerParagraphs('coverage')) {
      expect(visibleText).toContain(normalized(paragraph))
    }
    expect(visibleText).not.toContain(priorReply)
  })

  // Revert-check: the postscript veto in removeRepeatedSignature
  it('repeated postscript, remains authored content', () => {
    const results = [
      htmlPreview(
        fixtureHtml({ currentPostscript: newPostscript, historicalPostscript: newPostscript }),
      ),
      plainPreview(
        fixturePlainText({ currentPostscript: newPostscript, historicalPostscript: newPostscript }),
      ),
    ]
    for (const result of results) {
      expect(result.mainText).toContain(newPostscript)
    }
  })

  // Revert-check: the isAuthoredLeadInLine veto in removeRepeatedSignature
  it('authored signature template, is preserved even when repeated in history', () => {
    const text = [
      'Please review this signature template:',
      'Sincerely,',
      'Jane Doe',
      'Account Manager',
      'jane@example.test',
      '202-555-0101',
      'These terms remain under review.',
    ].join('\n')
    expect(removeRepeatedSignature(text, () => text)).toBe(text)
  })

  // Revert-check: the support-prose break in the contact window of removeRepeatedSignature
  it('contact evidence after authored prose, does not establish a signature', () => {
    const text = [
      'Here is the proposed draft.',
      'Sincerely,',
      'Jane Doe',
      'Account Manager',
      'Please contact the reviewers using these details.',
      'jane@example.test',
      '202-555-0101',
      'These terms remain under review.',
    ].join('\n')
    expect(removeRepeatedSignature(text, () => text)).toBe(text)
  })

  // Revert-check: the lazy quotedText projection in removeRepeatedSignature
  it('ordinary message, does not load the quoted source', () => {
    const text = 'Here is the update.\n\nPlease call when you are ready.'
    expect(
      removeRepeatedSignature(text, () => {
        throw new Error('Ordinary messages should not trigger another source projection')
      }),
    ).toBe(text)
  })

  // Revert-check: the isSignOff requirement in removeRepeatedSignature
  it('repeated directory without a closing, is preserved', () => {
    const text = [
      'Here are the contacts.',
      'Jane Doe',
      'Account Manager',
      'jane@example.test',
      '202-555-0101',
      'These terms remain under review.',
    ].join('\n')
    expect(removeRepeatedSignature(text, () => text)).toBe(text)
  })

  // Revert-check: removeRepeatedSignature call in bubble.ts processHtml
  it('HTML bubble, unsized cid logo vetoes DOM removal, repeated history still strips the footer', () => {
    // The unsized `<img src="cid:…">` makes the DOM pass keep the block and the
    // protected-structure guard skips the text pass; only the repeat in quoted
    // history can claim it.
    const signature = [
      '<div>Best regards,</div>',
      '<div>Jane Doe</div>',
      '<div>Senior Account Manager</div>',
      '<div><img src="cid:logo"></div>',
      '<div>Acme Corp</div>',
      '<div>Email: jane@acme.test</div>',
      '<div>Phone: 415-555-1212</div>',
    ].join('')
    const html =
      '<div>Sounds good, see you then.</div>' +
      signature +
      '<blockquote type="cite"><div>On Aug 1, 2026, at 9:00 AM, Bob Lee &lt;bob@example.test&gt; wrote:</div>' +
      '<div>Can we meet Friday?</div>' +
      '<blockquote type="cite"><div>On Jul 30, 2026, at 9:00 AM, Jane Doe &lt;jane@acme.test&gt; wrote:</div>' +
      '<div>Let me know a good time.</div>' +
      signature +
      '</blockquote></blockquote>'

    const result = processChatBubbleText(html, { inputKind: 'html' })
    expect(normalized(result.mainText)).toBe('Sounds good, see you then. Best regards, Jane Doe')
  })

  // Revert-check: removeRepeatedSignature call in text.ts extractQuotes
  it('extractQuotes, repeated footer, strips it before the heuristic signature pass', () => {
    const result = extractQuotes(fixturePlainText().replace(/\r\n/g, '\n'))
    expect(normalized(result.mainContent)).toBe(normalized(expectedChatText))
  })
})
