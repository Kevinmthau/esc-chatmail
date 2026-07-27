import { describe, expect, it } from 'vitest'
import {
  buildForwardHeaderHtml,
  buildForwardHtmlBody,
  buildForwardTextBlock,
  escapeHtml,
  extractUserNote,
  formatForwardDate,
  FORWARD_MARKER,
  plainTextToHtml,
  prefixSubjectForForward,
  type ForwardHeaderFields,
} from './forwardMetadata'

const HEADER: ForwardHeaderFields = {
  from: 'Bob Jones',
  date: 'Jul 27, 2026, 3:04 PM',
  subject: 'Quarterly numbers',
  to: 'me@example.com, dana@example.com',
}

describe('prefixSubjectForForward', () => {
  it("prefixes 'Fwd: '", () => {
    expect(prefixSubjectForForward('Quarterly numbers')).toBe('Fwd: Quarterly numbers')
  })

  it('trims before prefixing', () => {
    expect(prefixSubjectForForward('  Quarterly numbers  ')).toBe('Fwd: Quarterly numbers')
  })

  it('is idempotent — never double-prefixes an already-forwarded subject', () => {
    const once = prefixSubjectForForward('Quarterly numbers')
    expect(prefixSubjectForForward(once)).toBe(once)
    expect(prefixSubjectForForward('Fwd: Quarterly numbers')).toBe('Fwd: Quarterly numbers')
  })

  it('accepts the other forward prefixes case-insensitively', () => {
    expect(prefixSubjectForForward('FWD: numbers')).toBe('FWD: numbers')
    expect(prefixSubjectForForward('fw: numbers')).toBe('fw: numbers')
    expect(prefixSubjectForForward('Fw: numbers')).toBe('Fw: numbers')
  })

  it('still prefixes a reply subject (a forwarded reply is a forward)', () => {
    expect(prefixSubjectForForward('Re: numbers')).toBe('Fwd: Re: numbers')
  })

  it('leaves an empty subject empty rather than sending a bare prefix', () => {
    expect(prefixSubjectForForward('')).toBe('')
    expect(prefixSubjectForForward('   ')).toBe('')
  })
})

describe('formatForwardDate', () => {
  it('renders a medium date + short time (iOS DateFormatter parity)', () => {
    const formatted = formatForwardDate(Date.UTC(2026, 6, 27, 12, 0))
    expect(formatted).toMatch(/^Jul \d{1,2}, 2026, \d{1,2}:\d{2}\s?[AP]M$/u)
  })
})

describe('buildForwardTextBlock', () => {
  it('emits the marker, header lines and the original content', () => {
    expect(buildForwardTextBlock(HEADER, 'Numbers are in.')).toBe(
      [
        '',
        '',
        FORWARD_MARKER,
        'From: Bob Jones',
        'Date: Jul 27, 2026, 3:04 PM',
        'Subject: Quarterly numbers',
        'To: me@example.com, dana@example.com',
        '',
        'Numbers are in.',
      ].join('\n'),
    )
  })

  it('omits the Subject and To lines when the original had none', () => {
    const block = buildForwardTextBlock({ ...HEADER, subject: '', to: '' }, 'Body')
    expect(block).toBe(
      ['', '', FORWARD_MARKER, 'From: Bob Jones', 'Date: Jul 27, 2026, 3:04 PM', '', 'Body'].join(
        '\n',
      ),
    )
  })

  it('opens with blank lines so the user can type a note above it', () => {
    expect(buildForwardTextBlock(HEADER, 'Body').startsWith('\n\n')).toBe(true)
  })
})

describe('extractUserNote', () => {
  it('returns everything above the forwarded marker', () => {
    const body = `See below.${buildForwardTextBlock(HEADER, 'Numbers are in.')}`
    expect(extractUserNote(body)).toBe('See below.')
  })

  it('is empty when the user typed nothing above the block', () => {
    expect(extractUserNote(buildForwardTextBlock(HEADER, 'Numbers are in.'))).toBe('')
  })

  it('treats a body with no marker as entirely the user note', () => {
    expect(extractUserNote('  just a note  ')).toBe('just a note')
  })

  it('recognizes the longer/shorter marker variants other clients emit', () => {
    expect(extractUserNote('note\n---------- Forwarded message ----------\nFrom: x')).toBe('note')
    expect(extractUserNote('note\n----- Forwarded message -----\nFrom: x')).toBe('note')
  })
})

describe('escapeHtml / plainTextToHtml', () => {
  it('escapes the five specials', () => {
    expect(escapeHtml(`<b>&"'`)).toBe('&lt;b&gt;&amp;&quot;&#39;')
  })

  it('escapes user text before it becomes markup', () => {
    const html = plainTextToHtml('<script>alert(1)</script>')
    expect(html).not.toContain('<script')
    expect(html).toContain('&lt;script&gt;')
  })

  it('wraps a single paragraph in a div and converts newlines to <br>', () => {
    expect(plainTextToHtml('one\ntwo')).toBe('<div style="margin: 0;">one<br>\ntwo</div>')
  })

  it('splits double newlines into paragraphs', () => {
    const html = plainTextToHtml('one\n\ntwo')
    expect(html).toBe(
      '<p style="margin: 0 0 1em 0;">one</p>\n<p style="margin: 0 0 1em 0;">two</p>',
    )
  })

  it('auto-links http(s) and bare www URLs', () => {
    expect(plainTextToHtml('see https://example.com/x')).toContain(
      '<a href="https://example.com/x"',
    )
    expect(plainTextToHtml('see www.example.com')).toContain('<a href="https://www.example.com"')
  })
})

describe('buildForwardHeaderHtml', () => {
  it('escapes every interpolated header field', () => {
    const html = buildForwardHeaderHtml({
      from: '<img src=x onerror=alert(1)>',
      date: 'Jul 27, 2026, 3:04 PM',
      subject: 'a & b',
      to: '"quoted"@example.com',
    })
    expect(html).not.toContain('<img')
    expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;')
    expect(html).toContain('a &amp; b')
    expect(html).toContain('&quot;quoted&quot;@example.com')
  })

  it('omits the Subject and To rows when they are empty', () => {
    const html = buildForwardHeaderHtml({ ...HEADER, subject: '', to: '' })
    expect(html).not.toContain('<strong>Subject:</strong>')
    expect(html).not.toContain('<strong>To:</strong>')
    expect(html).toContain('<strong>From:</strong> Bob Jones')
  })
})

describe('buildForwardHtmlBody', () => {
  const content = '<p>Numbers are in.</p>'

  it('puts the user note above the header block, then the original content', () => {
    const html = buildForwardHtmlBody({
      userNote: 'See below.',
      header: HEADER,
      sanitizedContentHtml: content,
    })
    expect(html.indexOf('See below.')).toBeLessThan(html.indexOf(FORWARD_MARKER))
    expect(html.indexOf(FORWARD_MARKER)).toBeLessThan(html.indexOf('Numbers are in.'))
    expect(html.startsWith('<!DOCTYPE html>')).toBe(true)
    expect(html.trimEnd().endsWith('</html>')).toBe(true)
  })

  it('emits no note block when the user added nothing', () => {
    const html = buildForwardHtmlBody({
      userNote: '   ',
      header: HEADER,
      sanitizedContentHtml: content,
    })
    expect(html).not.toContain('margin-bottom: 20px')
    expect(html).toContain(FORWARD_MARKER)
  })

  it('escapes a note that looks like markup', () => {
    const html = buildForwardHtmlBody({
      userNote: '<script>alert(1)</script>',
      header: HEADER,
      sanitizedContentHtml: content,
    })
    expect(html).not.toContain('<script')
  })
})
