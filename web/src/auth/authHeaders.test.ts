// Pins the site-wide CSP against the Google Identity Services endpoints the
// auth broker actually talks to.
//
// CSP source expressions here carry a PATH, and a path-carrying source only
// matches URLs under that path. `https://accounts.google.com/gsi/` therefore
// does NOT cover `https://accounts.google.com/o/oauth2/revoke`, which is what
// `google.accounts.oauth2.revoke()` hits on sign-out. A blocked revocation is
// invisible to the app (the refusal is not a synchronous throw), so the grant
// would stay live at Google after the user signed out on a shared machine.

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { describe, expect, it } from 'vitest'

function findHeadersFile(): string {
  let dir = process.cwd()
  for (let i = 0; i < 6; i++) {
    if (existsSync(join(dir, 'public', '_headers'))) return join(dir, 'public', '_headers')
    dir = dirname(dir)
  }
  throw new Error('public/_headers not found above cwd')
}

/** The `/*` rule's CSP, split into directive → source list. */
function siteDirectives(): Map<string, string[]> {
  const text = readFileSync(findHeadersFile(), 'utf8')
  const line = text
    .split('\n')
    .map((raw) => raw.trim())
    .find((raw) => raw.startsWith('Content-Security-Policy:'))
  if (line === undefined) throw new Error('no site-wide Content-Security-Policy in _headers')
  const policy = line.slice('Content-Security-Policy:'.length).trim()
  const directives = new Map<string, string[]>()
  for (const part of policy.split(';')) {
    const tokens = part.trim().split(/\s+/).filter(Boolean)
    const name = tokens.shift()
    if (name !== undefined) directives.set(name, tokens)
  }
  return directives
}

/** Mirrors the CSP host-source path rule: a source ending in `/` is a prefix. */
function allows(sources: string[], url: string): boolean {
  return sources.some((source) => {
    if (!source.startsWith('https://')) return false
    if (source.endsWith('/')) return url.startsWith(source)
    return url === source || url.startsWith(`${source}?`)
  })
}

describe('site-wide CSP vs. the GIS endpoints the broker uses', () => {
  const directives = siteDirectives()

  it('allows the token-client script and its frames', () => {
    expect(
      allows(directives.get('script-src') ?? [], 'https://accounts.google.com/gsi/client'),
    ).toBe(true)
    expect(
      allows(directives.get('frame-src') ?? [], 'https://accounts.google.com/gsi/iframe/select'),
    ).toBe(true)
  })

  it('allows sign-out revocation', () => {
    // Regression: connect-src/frame-src listed only /gsi/, so the revoke call
    // was refused by the policy and sign-out reported success while the grant
    // stayed valid at Google.
    const revoke = 'https://accounts.google.com/o/oauth2/revoke?token=abc'
    expect(allows(directives.get('connect-src') ?? [], revoke)).toBe(true)
    expect(allows(directives.get('frame-src') ?? [], revoke)).toBe(true)
  })

  it('allows the Gmail and OAuth token endpoints', () => {
    const connect = directives.get('connect-src') ?? []
    expect(connect).toContain('https://gmail.googleapis.com')
    expect(connect).toContain('https://oauth2.googleapis.com')
  })

  it('stays tight everywhere else', () => {
    expect(directives.get('default-src')).toEqual(["'self'"])
    expect(directives.get('object-src')).toEqual(["'none'"])
    expect(directives.get('base-uri')).toEqual(["'none'"])
    expect(directives.get('frame-ancestors')).toEqual(["'none'"])
    // No wildcard/scheme-only source may creep into the network directives.
    for (const name of ['connect-src', 'frame-src', 'script-src']) {
      for (const source of directives.get(name) ?? []) {
        expect(source).not.toBe('*')
        expect(source).not.toBe('https:')
      }
    }
  })
})
