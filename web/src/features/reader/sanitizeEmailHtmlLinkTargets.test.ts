// sanitizeEmailHtml link handling: image-map areas are links (target/rel like
// anchors) and private-network link targets are refused, as on iOS.

import { describe, expect, it } from 'vitest'
import { patchHappyDomForDomPurify } from './happyDomPatch'
import { sanitizeEmailHtml } from './sanitizeEmailHtml'

// Must run before the first sanitize call (DOMPurify caches document methods
// and Node.prototype getters when its module initializes).
patchHappyDomForDomPurify()

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, 'text/html')
}

// A public-looking attacker host: `.example` is a reserved TLD and would be
// refused by the private-network rule before the target rule is observed.
const IMAGE_MAP =
  '<img usemap="#m" src="https://cdn.attacker-cdn.com/x.png" width="600" height="400">' +
  '<map name="m"><area shape="default" href="https://attacker-site.com/fake-login"></map>'

describe('sanitizeEmailHtml image-map areas', () => {
  // Revert-check: the `a, area` selector in sanitizeEmailHtml (an untreated area has no target)
  it('sanitizeEmailHtml_imageMapArea_opensOutsideTheFrameLikeAnAnchor', async () => {
    const { html } = await sanitizeEmailHtml(IMAGE_MAP, { mode: 'full' })
    const area = parse(html).querySelector('area')
    expect(area).not.toBeNull()
    expect(area?.getAttribute('href')).toBe('https://attacker-site.com/fake-login')
    expect(area?.getAttribute('target')).toBe('_blank')
    expect(area?.getAttribute('rel')).toBe('noopener noreferrer')
  })

  it('sanitizeEmailHtml_imageMapArea_overridesAnAuthoredSelfTarget', async () => {
    const { html } = await sanitizeEmailHtml(
      '<map name="m"><area href="https://a-site.com/" target="_self" rel="opener"></map>',
      { mode: 'full' },
    )
    const area = parse(html).querySelector('area')
    expect(area?.getAttribute('target')).toBe('_blank')
    expect(area?.getAttribute('rel')).toBe('noopener noreferrer')
  })
})

describe('sanitizeEmailHtml private-network links', () => {
  // Revert-check: isBlockedPrivateNetworkLink in sanitizeEmailHtml
  it('sanitizeEmailHtml_anchorToPrivateHost_losesItsHref', async () => {
    const { html } = await sanitizeEmailHtml(
      '<a href="http://127.0.0.1:8080/admin/reboot">reboot</a>' +
        '<a href="http://192.168.0.1/cgi-bin/reboot">View invoice</a>' +
        '<a href="http://[::1]/">v6</a>' +
        '<a href="http://169.254.169.254/latest/meta-data/">meta</a>' +
        '<a href="https://router.local/">mdns</a>' +
        '<a href="http://intranet/">single</a>' +
        '<a href="HTTP://10.0.0.5/">upper</a>',
      { mode: 'full' },
    )
    const anchors = Array.from(parse(html).querySelectorAll('a'))
    expect(anchors).toHaveLength(7)
    for (const anchor of anchors) {
      expect(anchor.hasAttribute('href'), anchor.textContent ?? '').toBe(false)
    }
    expect(html).toContain('View invoice')
    expect(html).not.toContain('192.168.0.1')
  })

  // Revert-check: isBlockedPrivateNetworkLink
  it('sanitizeEmailHtml_imageMapAreaToPrivateHost_losesItsHref', async () => {
    const { html } = await sanitizeEmailHtml(
      '<map name="m"><area shape="rect" coords="0,0,10,10" href="http://10.0.0.5/x"></map>',
      { mode: 'full' },
    )
    expect(parse(html).querySelector('area')?.hasAttribute('href')).toBe(false)
  })

  it('sanitizeEmailHtml_anchorToPublicHost_keepsItsHref', async () => {
    const { html } = await sanitizeEmailHtml(
      '<a href="https://example.com/invoice">invoice</a>' +
        '<a href="mailto:alice@example.com">mail</a>' +
        '<a href="tel:+15551234567">call</a>' +
        '<a href="#section">jump</a>' +
        '<a href="docs/readme.html">relative</a>',
      { mode: 'full' },
    )
    const hrefs = Array.from(parse(html).querySelectorAll('a')).map((a) => a.getAttribute('href'))
    expect(hrefs).toEqual([
      'https://example.com/invoice',
      'mailto:alice@example.com',
      'tel:+15551234567',
      '#section',
      'docs/readme.html',
    ])
  })

  // The image half is deliberately not a divergence: iOS's WKWebView loads
  // private-host <img> sources too (its private-network guards cover only
  // app-process fetches).
  it('sanitizeEmailHtml_imageOnPrivateHost_isLeftAlone', async () => {
    const { html } = await sanitizeEmailHtml(
      '<img src="http://192.168.1.1/x.png"><img src="http://127.0.0.1:8080/y.png">',
      { mode: 'full' },
    )
    const srcs = Array.from(parse(html).querySelectorAll('img')).map((img) =>
      img.getAttribute('src'),
    )
    expect(srcs).toEqual(['http://192.168.1.1/x.png', 'http://127.0.0.1:8080/y.png'])
  })
})
