import { describe, expect, it, vi } from 'vitest'
import { patchHappyDomForDomPurify } from './happyDomPatch'
import { sanitizeEmailHtml } from './sanitizeEmailHtml'

// Must run before the first sanitize call (DOMPurify caches document methods
// and Node.prototype getters when its module initializes).
patchHappyDomForDomPurify()

const CSP_CONTENT =
  "default-src 'none'; img-src https: http: data: blob: cid:; " +
  "style-src 'unsafe-inline'; font-src https: data:"

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, 'text/html')
}

describe('sanitizeEmailHtml', () => {
  it('strips script, iframe, object, embed, form, base and email-authored meta', async () => {
    const { html } = await sanitizeEmailHtml(
      `<html><head>
        <base href="https://evil.example/">
        <meta http-equiv="refresh" content="0;url=https://evil.example">
        <link rel="stylesheet" href="https://evil.example/x.css">
      </head><body>
        <script>alert(1)</script>
        <iframe src="https://evil.example"></iframe>
        <object data="https://evil.example"></object>
        <embed src="https://evil.example">
        <form action="https://evil.example"><input name="pw"></form>
        <p>Hello</p>
      </body></html>`,
      { mode: 'full' },
    )
    expect(html).not.toContain('<script')
    expect(html).not.toContain('<iframe')
    expect(html).not.toContain('<object')
    expect(html).not.toContain('<embed')
    expect(html).not.toContain('<form')
    expect(html).not.toContain('<base')
    expect(html).not.toContain('refresh')
    expect(html).not.toContain('stylesheet')
    expect(html).toContain('Hello')
  })

  it('removes event-handler attributes', async () => {
    const { html } = await sanitizeEmailHtml(
      '<img src="https://x.example/a.png" onerror="alert(1)"><div onclick="alert(2)">t</div>',
      { mode: 'full' },
    )
    expect(html).not.toContain('onerror')
    expect(html).not.toContain('onclick')
  })

  it('removes javascript: hrefs', async () => {
    const { html } = await sanitizeEmailHtml('<a href="javascript:alert(1)">click</a>', {
      mode: 'full',
    })
    expect(html.toLowerCase()).not.toContain('javascript:')
    expect(html).toContain('click')
  })

  it('collects and normalizes cid image references', async () => {
    const { html, cids } = await sanitizeEmailHtml(
      '<img src="cid:<logo@example>"><img src="cid:photo@example"><img src="cid:logo@example">',
      { mode: 'full' },
    )
    expect(cids).toEqual(['logo@example', 'photo@example'])
    const doc = parse(html)
    const srcs = Array.from(doc.querySelectorAll('img')).map((img) => img.getAttribute('src'))
    expect(srcs).toEqual(['cid:logo@example', 'cid:photo@example', 'cid:logo@example'])
  })

  it('forces target=_blank and rel=noopener noreferrer on every anchor', async () => {
    const { html } = await sanitizeEmailHtml(
      '<a href="https://a.example">a</a><a href="https://b.example" target="_self" rel="opener">b</a>',
      { mode: 'full' },
    )
    const anchors = Array.from(parse(html).querySelectorAll('a'))
    expect(anchors).toHaveLength(2)
    for (const anchor of anchors) {
      expect(anchor.getAttribute('target')).toBe('_blank')
      expect(anchor.getAttribute('rel')).toBe('noopener noreferrer')
    }
  })

  it('injects the CSP meta as the first head child', async () => {
    const { html } = await sanitizeEmailHtml('<p>x</p>', { mode: 'full' })
    const doc = parse(html)
    const meta = doc.querySelector('meta[http-equiv="Content-Security-Policy"]')
    expect(meta).not.toBeNull()
    expect(meta?.getAttribute('content')).toBe(CSP_CONTENT)
  })

  it('injects base styles; preview mode additionally hides overflow', async () => {
    const full = await sanitizeEmailHtml('<p>x</p>', { mode: 'full' })
    expect(full.html).toContain('color-scheme:light only')
    expect(full.html).toContain('overflow-wrap:break-word')
    expect(full.html).not.toContain('html,body{overflow:hidden}')

    const preview = await sanitizeEmailHtml('<p>x</p>', { mode: 'preview' })
    expect(preview.html).toContain('html,body{overflow:hidden}')
  })

  it('keeps <style> blocks and inline styles (emails need them)', async () => {
    const { html } = await sanitizeEmailHtml(
      '<html><head><style>.a{color:red}</style></head><body><p style="font-weight:bold">x</p></body></html>',
      { mode: 'full' },
    )
    expect(html).toContain('.a{color:red}')
    expect(html).toContain('font-weight:bold')
  })

  it('keeps https and data: image sources', async () => {
    const { html, cids } = await sanitizeEmailHtml(
      '<img src="https://x.example/a.png"><img src="data:image/gif;base64,R0lGOD">',
      { mode: 'full' },
    )
    expect(html).toContain('https://x.example/a.png')
    expect(html).toContain('data:image/gif;base64,R0lGOD')
    expect(cids).toEqual([])
  })

  // DOMPurify applies ALLOWED_URI_REGEXP to the value of EVERY allowed
  // attribute that is not in URI_SAFE_ATTRIBUTES — width, bgcolor, align,
  // colspan, SVG geometry, ... — not just real URI attributes. A scheme-only
  // pattern therefore strips the layout attributes table-based emails are
  // built from.
  it('keeps non-URI layout attributes on table emails', async () => {
    const { html } = await sanitizeEmailHtml(
      '<table width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff">' +
        '<tr><td align="center" colspan="2" height="40" valign="top">cell</td></tr>' +
        '</table>' +
        '<font color="#336699" face="Arial">legacy</font>',
      { mode: 'full' },
    )
    const doc = parse(html)
    const table = doc.querySelector('table')
    expect(table?.getAttribute('width')).toBe('600')
    expect(table?.getAttribute('cellpadding')).toBe('0')
    expect(table?.getAttribute('cellspacing')).toBe('0')
    expect(table?.getAttribute('border')).toBe('0')
    expect(table?.getAttribute('bgcolor')).toBe('#ffffff')
    const td = doc.querySelector('td')
    expect(td?.getAttribute('align')).toBe('center')
    expect(td?.getAttribute('colspan')).toBe('2')
    expect(td?.getAttribute('height')).toBe('40')
    expect(td?.getAttribute('valign')).toBe('top')
    const font = doc.querySelector('font')
    expect(font?.getAttribute('color')).toBe('#336699')
    expect(font?.getAttribute('face')).toBe('Arial')
  })

  it('keeps fragment-only and relative hrefs/srcs', async () => {
    const { html } = await sanitizeEmailHtml(
      '<a href="#section">jump</a><img src="images/logo.png">',
      { mode: 'full' },
    )
    const doc = parse(html)
    expect(doc.querySelector('a')?.getAttribute('href')).toBe('#section')
    expect(doc.querySelector('img')?.getAttribute('src')).toBe('images/logo.png')
  })

  it('keeps SVG geometry attributes', async () => {
    const { html } = await sanitizeEmailHtml(
      '<svg viewBox="0 0 10 10" width="10" height="10"><path d="M0 0L10 10"></path></svg>',
      { mode: 'full' },
    )
    const doc = parse(html)
    expect(doc.querySelector('svg')?.getAttribute('viewBox')).toBe('0 0 10 10')
    expect(doc.querySelector('path')?.getAttribute('d')).toBe('M0 0L10 10')
  })

  it('blocks javascript:, vbscript: and data:text/html links while keeping cid/https images', async () => {
    const { html } = await sanitizeEmailHtml(
      '<a href="javascript:alert(1)">a</a>' +
        '<a href="vbscript:msgbox(1)">b</a>' +
        '<a href="data:text/html;base64,PHNjcmlwdD4=">c</a>' +
        '<img src="cid:logo@example"><img src="https://x.example/i.png">',
      { mode: 'full' },
    )
    const lower = html.toLowerCase()
    expect(lower).not.toContain('javascript:')
    expect(lower).not.toContain('vbscript:')
    expect(lower).not.toContain('data:text/html')
    expect(html).toContain('cid:logo@example')
    expect(html).toContain('https://x.example/i.png')
  })

  // The frame (public/email-frame.js) re-parses the payload with
  // DOMParser('text/html'), where <style> is raw text and character
  // references are NOT decoded. XML serialization escapes '&'/'<'/'>' inside
  // every text node including <style>, so an XML-serialized payload hands the
  // CSS parser literal '&gt;'/'&amp;' — child combinators and url() query
  // strings silently break. The payload must be serialized with HTML rules.
  it('round-trips <style> raw text intact through the frame text/html re-parse', async () => {
    const { html } = await sanitizeEmailHtml(
      '<html><head><style>.wrap > td { color: red } .u { background: url(/a?x=1&y=2) }</style>' +
        '</head><body><table><tr><td class="wrap"><td>x</td></td></tr></table></body></html>',
      { mode: 'full' },
    )
    const doc = parse(html)
    const css = Array.from(doc.querySelectorAll('style'))
      .map((style) => style.textContent ?? '')
      .join('\n')
    expect(css).toContain('.wrap > td { color: red }')
    expect(css).toContain('url(/a?x=1&y=2)')
    expect(css).not.toContain('&gt;')
    expect(css).not.toContain('&amp;')
  })

  it('never serializes through XMLSerializer (browsers XML-escape <style> text)', async () => {
    // happy-dom's XMLSerializer under-escapes compared to real browsers, so
    // the round-trip test above cannot catch an XMLSerializer regression on
    // its own. Stub the global with output faithful to what Chromium's
    // XMLSerializer produces for this input (escaped '>' inside <style>): if
    // the sanitizer ever serializes via XMLSerializer again, the frame
    // round-trip below sees the corrupted CSS and fails.
    const chromiumFaithfulXml =
      '<html xmlns="http://www.w3.org/1999/xhtml"><head>' +
      '<style>.wrap &gt; td { color: red }</style></head>' +
      '<body><p>x</p></body></html>'
    vi.stubGlobal(
      'XMLSerializer',
      class {
        serializeToString(): string {
          return chromiumFaithfulXml
        }
      },
    )
    try {
      const { html } = await sanitizeEmailHtml(
        '<html><head><style>.wrap > td { color: red }</style></head><body><p>x</p></body></html>',
        { mode: 'full' },
      )
      const doc = parse(html)
      const css = Array.from(doc.querySelectorAll('style'))
        .map((style) => style.textContent ?? '')
        .join('\n')
      expect(css).toContain('.wrap > td { color: red }')
      expect(css).not.toContain('&gt;')
    } finally {
      vi.unstubAllGlobals()
    }
  })

  it('mixed-content email retains its body content through the frame round-trip', async () => {
    const { html } = await sanitizeEmailHtml(
      '<html><head><style></style></head><body>' +
        '<p>intro</p><table><tr><td>cell one</td></tr></table><p>outro</p>' +
        '</body></html>',
      { mode: 'full' },
    )
    const doc = parse(html)
    expect(doc.body?.textContent).toContain('intro')
    expect(doc.body?.textContent).toContain('cell one')
    expect(doc.body?.textContent).toContain('outro')
  })
})
