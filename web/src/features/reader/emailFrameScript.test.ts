// Behavior tests for public/email-frame.js — the render path that rewrites
// cid: carriers (img src, srcset, background, url() in inline styles and
// <style> text) to object URLs minted from the posted Blobs.
//
// The script is a plain IIFE written for the sandboxed frame document, so it
// is evaluated once into this file's happy-dom globals and driven through its
// real interface: a 'message' event carrying {type:'render', html, cidBlobs}.
// The listener renders synchronously into this document, which the tests then
// inspect. URL.createObjectURL is stubbed to mint deterministic URLs.

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { runInThisContext } from 'node:vm'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'

// import.meta.url is not a file: URL under vitest's transform, so locate
// public/ by walking up from the working directory (web/ locally and in CI).
function findPublicDir(): string {
  let dir = process.cwd()
  for (let i = 0; i < 6; i++) {
    if (existsSync(join(dir, 'public', 'email-frame.js'))) return join(dir, 'public')
    dir = dirname(dir)
  }
  throw new Error('public/email-frame.js not found above cwd')
}

let minted: string[] = []

beforeAll(() => {
  const source = readFileSync(join(findPublicDir(), 'email-frame.js'), 'utf8')
  // Evaluate exactly once: the IIFE registers its message listener on the
  // global window, and a second evaluation would double-render every message.
  runInThisContext(source, { filename: 'email-frame.js' })
})

beforeEach(() => {
  minted = []
  URL.createObjectURL = () => {
    const url = `blob:mock-${minted.length + 1}`
    minted.push(url)
    return url
  }
  URL.revokeObjectURL = () => undefined
})

/**
 * Posts a render message the way EmailFrame does. Object-URL minting walks
 * cidBlobs in key insertion order, so the Nth key maps to `blob:mock-N`.
 */
function renderInFrame(html: string, cids: string[]): void {
  const cidBlobs: Record<string, Blob> = {}
  for (const cid of cids) cidBlobs[cid] = new Blob(['x'], { type: 'image/png' })
  window.dispatchEvent(new MessageEvent('message', { data: { type: 'render', html, cidBlobs } }))
}

describe('email-frame render', () => {
  it('rewrites resolved cid img src to an object URL and drops unresolved src', () => {
    renderInFrame('<img src="cid:<logo@x>" alt="a"><img src="cid:missing@x" alt="b">', ['logo@x'])
    const imgs = Array.from(document.querySelectorAll('img'))
    expect(imgs[0]?.getAttribute('src')).toBe('blob:mock-1')
    expect(imgs[1]?.hasAttribute('src')).toBe(false)
  })

  it('removes a fully unresolved cid srcset so the rewritten src can win', () => {
    // The headline gap: srcset shadows src in modern browsers, so leaving
    // `srcset="cid:..."` behind rendered the image blank even with a resolved
    // src pointing at a freshly minted object URL.
    renderInFrame('<img src="cid:logo@x" srcset="cid:missing@x 1x, cid:missing2@x 2x">', ['logo@x'])
    const img = document.querySelector('img')
    expect(img?.getAttribute('src')).toBe('blob:mock-1')
    expect(img?.hasAttribute('srcset')).toBe(false)
  })

  it('rewrites resolved srcset candidates and drops only the unresolved ones', () => {
    renderInFrame('<img srcset="cid:<logo@x> 1x, cid:missing@x 2x, https://x.example/f.png 3x">', [
      'logo@x',
    ])
    expect(document.querySelector('img')?.getAttribute('srcset')).toBe(
      'blob:mock-1 1x, https://x.example/f.png 3x',
    )
  })

  it('leaves srcsets without cid candidates untouched', () => {
    const srcset = 'https://x.example/a.png 1x,data:image/png;base64,AAA 2x'
    renderInFrame(`<img srcset="${srcset}">`, [])
    expect(document.querySelector('img')?.getAttribute('srcset')).toBe(srcset)
  })

  it('rewrites resolved background attributes and removes unresolved ones', () => {
    renderInFrame(
      '<table><tbody><tr>' +
        '<td background="cid:bg@x">one</td>' +
        '<td background="cid:missing@x">two</td>' +
        '<td background="https://x.example/t.png">three</td>' +
        '</tr></tbody></table>',
      ['bg@x'],
    )
    const tds = Array.from(document.querySelectorAll('td'))
    expect(tds[0]?.getAttribute('background')).toBe('blob:mock-1')
    expect(tds[1]?.hasAttribute('background')).toBe(false)
    expect(tds[2]?.getAttribute('background')).toBe('https://x.example/t.png')
  })

  it('rewrites url(cid:) in inline styles and blanks unresolved references', () => {
    renderInFrame(
      '<div style="background-image: url(cid:paper@x)">a</div>' +
        '<div style="background: #001 url(\'cid:missing@x\') repeat">b</div>',
      ['paper@x'],
    )
    const divs = Array.from(document.querySelectorAll('div'))
    expect(divs[0]?.getAttribute('style')).toBe('background-image: url("blob:mock-1")')
    expect(divs[1]?.getAttribute('style')).toBe('background: #001 none repeat')
  })

  it('rewrites url(cid:) in <style> element text and blanks unresolved references', () => {
    renderInFrame(
      '<html><head><style>.a { background: url(cid:paper@x) }</style></head><body>' +
        "<style>.b { background: #001 url('cid:missing@x') repeat }</style><p>x</p></body></html>",
      ['paper@x'],
    )
    const css = Array.from(document.querySelectorAll('style'))
      .map((style) => style.textContent ?? '')
      .join('\n')
    expect(css).toContain('.a { background: url("blob:mock-1") }')
    expect(css).toContain('.b { background: #001 none repeat }')
  })
})
