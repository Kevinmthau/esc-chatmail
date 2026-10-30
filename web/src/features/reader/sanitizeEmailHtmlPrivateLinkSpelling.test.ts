// The private-network link rule classifies the URL the browser resolves, not
// the attribute's spelling: the sanitized document lives on the app's https
// origin, so a scheme-relative href resolves to https, and the URL parser
// strips ASCII tab/LF/CR anywhere in the input.

import { describe, expect, it } from 'vitest'
import { patchHappyDomForDomPurify } from './happyDomPatch'
import { sanitizeEmailHtml } from './sanitizeEmailHtml'

patchHappyDomForDomPurify()

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, 'text/html')
}

async function hrefAfterSanitize(href: string): Promise<string | null> {
  const { html } = await sanitizeEmailHtml(`<a href="${href}">View invoice</a>`, { mode: 'full' })
  return parse(html).querySelector('a')?.getAttribute('href') ?? null
}

describe('sanitizeEmailHtml private-network links by resolved URL', () => {
  // Revert-check: the scheme-relative and tab/LF/CR handling in
  // isBlockedPrivateNetworkLink (a literal /^https?:/ test on the raw href
  // lets every one of these through).
  it('sanitizeEmailHtml_schemeRelativePrivateHost_dropsTheHref', async () => {
    expect(await hrefAfterSanitize('//10.0.0.1/admin')).toBeNull()
    expect(await hrefAfterSanitize('//[::1]/admin')).toBeNull()
  })

  it('sanitizeEmailHtml_tabAndNewlineLacedPrivateHref_dropsTheHref', async () => {
    expect(await hrefAfterSanitize('ht\ttp://10.0.0.1/admin')).toBeNull()
    expect(await hrefAfterSanitize('\nhttps://192.168.1.1/')).toBeNull()
    expect(await hrefAfterSanitize('  http://127.0.0.1:8080/reboot')).toBeNull()
  })

  // Revert-check: resolving the href against RELATIVE_HREF_BASE in
  // isBlockedPrivateNetworkLink (the earlier literal "//" prefix test read
  // every one of these as a relative link and let it through, and the frame
  // resolves a backslash as a slash in an http(s) URL).
  it('sanitizeEmailHtml_backslashSchemeRelativePrivateHost_dropsTheHref', async () => {
    expect(await hrefAfterSanitize('\\\\192.168.1.1/admin')).toBeNull()
    expect(await hrefAfterSanitize('/\\10.0.0.1/')).toBeNull()
    expect(await hrefAfterSanitize('\\/127.0.0.1/reboot')).toBeNull()
    expect(await hrefAfterSanitize('///169.254.169.254/latest/meta-data/')).toBeNull()
    expect(await hrefAfterSanitize('\\\\\\\\[fd00::1]/')).toBeNull()
  })

  it('sanitizeEmailHtml_backslashSchemeRelativePublicHost_keepsTheHref', async () => {
    expect(await hrefAfterSanitize('\\\\cdn.public-site.com/doc')).toBe(
      '\\\\cdn.public-site.com/doc',
    )
  })

  it('sanitizeEmailHtml_publicAndNonHttpHrefs_keepTheirHref', async () => {
    expect(await hrefAfterSanitize('//cdn.public-site.com/doc')).toBe('//cdn.public-site.com/doc')
    expect(await hrefAfterSanitize('https://public-site.com/doc')).toBe(
      'https://public-site.com/doc',
    )
    expect(await hrefAfterSanitize('mailto:someone@public-site.com')).toBe(
      'mailto:someone@public-site.com',
    )
    expect(await hrefAfterSanitize('#section-2')).toBe('#section-2')
    expect(await hrefAfterSanitize('?page=2')).toBe('?page=2')
    expect(await hrefAfterSanitize('invoices/2026.pdf')).toBe('invoices/2026.pdf')
    expect(await hrefAfterSanitize('/invoices/2026.pdf')).toBe('/invoices/2026.pdf')
  })
})
