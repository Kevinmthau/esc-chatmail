// Pins the production header configuration for the email frame.
//
// Cloudflare Pages (and Netlify) `_headers` rules ACCUMULATE: a request for
// /email-frame.html matches both `/*` and `/email-frame.html`, and a second
// Content-Security-Policy value is APPENDED, which browsers enforce as the
// INTERSECTION of both policies. The site-wide policy's `img-src 'self'` would
// block remote email images and its `frame-ancestors 'none'` would refuse the
// reader iframe outright — so the frame rule must detach the site-wide CSP
// (`! Content-Security-Policy`) before setting its own.
//
// The simulation below mirrors the actual Cloudflare Pages asset-server
// algorithm (workers-sdk packages/pages-shared/asset-server/handler.ts):
// matched rules apply in file order; each rule's `! Header` removals run
// before its own sets; a header name set by an earlier rule causes later sets
// to append (comma-joined, per Headers.append).

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { describe, expect, it } from 'vitest'

// import.meta.url is not a file: URL under vitest's transform, so locate
// public/ by walking up from the working directory (web/ locally and in CI).
function findPublicDir(): string {
  let dir = process.cwd()
  for (let i = 0; i < 6; i++) {
    if (existsSync(join(dir, 'public', '_headers'))) return join(dir, 'public')
    dir = dirname(dir)
  }
  throw new Error('public/_headers not found above cwd')
}

const PUBLIC_DIR = findPublicDir()
const HEADERS_FILE = join(PUBLIC_DIR, '_headers')
const FRAME_HTML_FILE = join(PUBLIC_DIR, 'email-frame.html')

interface HeaderRule {
  path: string
  set: [name: string, value: string][]
  unset: string[]
}

function parseHeadersFile(text: string): HeaderRule[] {
  const rules: HeaderRule[] = []
  let current: HeaderRule | null = null
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line.length === 0 || line.startsWith('#')) continue
    if (line.startsWith('/')) {
      current = { path: line, set: [], unset: [] }
      rules.push(current)
      continue
    }
    if (current === null) throw new Error(`_headers: header line before any path: ${line}`)
    if (line.startsWith('! ')) {
      current.unset.push(line.slice(2).trim().toLowerCase())
      continue
    }
    const sep = line.indexOf(':')
    if (sep === -1) throw new Error(`_headers: malformed header line: ${line}`)
    current.set.push([line.slice(0, sep).trim().toLowerCase(), line.slice(sep + 1).trim()])
  }
  return rules
}

/** Exact paths and trailing-splat patterns only — enough for this file. */
function ruleMatches(rulePath: string, requestPath: string): boolean {
  if (rulePath.includes(':')) throw new Error(`placeholder patterns not supported: ${rulePath}`)
  if (rulePath.endsWith('*')) {
    const prefix = rulePath.slice(0, -1)
    if (prefix.includes('*')) throw new Error(`pattern not supported: ${rulePath}`)
    return requestPath.startsWith(prefix)
  }
  if (rulePath.includes('*')) throw new Error(`pattern not supported: ${rulePath}`)
  return rulePath === requestPath
}

function applyHeaders(rules: HeaderRule[], requestPath: string): Map<string, string> {
  const headers = new Map<string, string>()
  const setByAnyRule = new Set<string>()
  for (const rule of rules) {
    if (!ruleMatches(rule.path, requestPath)) continue
    for (const name of rule.unset) headers.delete(name)
    for (const [name, value] of rule.set) {
      const existing = headers.get(name)
      if (setByAnyRule.has(name) && existing !== undefined) {
        headers.set(name, `${existing}, ${value}`) // Headers.append semantics
      } else {
        headers.set(name, value)
        setByAnyRule.add(name)
      }
    }
  }
  return headers
}

const rules = parseHeadersFile(readFileSync(HEADERS_FILE, 'utf8'))

describe('public/_headers email-frame CSP', () => {
  it('serves exactly one CSP for /email-frame.html — the frame policy, not an intersection', () => {
    const headers = applyHeaders(rules, '/email-frame.html')
    const csp = headers.get('content-security-policy')
    expect(csp).toBeDefined()
    // A comma means two policies were appended; browsers enforce both
    // (intersection), silently re-imposing the site-wide restrictions.
    expect(csp).not.toContain(',')
    expect(csp).toContain("default-src 'none'")
    // Remote email images must load inside the frame.
    expect(csp).toContain('img-src https: http: data: blob:')
    // The app must be able to embed the frame; 'none' would refuse it.
    expect(csp).not.toContain("frame-ancestors 'none'")
    expect(csp).toContain("frame-ancestors 'self'")
  })

  it('still applies the non-CSP hardening headers to the frame', () => {
    const headers = applyHeaders(rules, '/email-frame.html')
    expect(headers.get('x-content-type-options')).toBe('nosniff')
    expect(headers.get('referrer-policy')).toBe('strict-origin-when-cross-origin')
  })

  it('keeps the hardened site-wide CSP on app documents', () => {
    const headers = applyHeaders(rules, '/')
    const csp = headers.get('content-security-policy')
    expect(csp).toBeDefined()
    expect(csp).not.toContain(',')
    expect(csp).toContain("default-src 'self'")
    expect(csp).toContain("frame-ancestors 'none'")

    const chats = applyHeaders(rules, '/chats').get('content-security-policy')
    expect(chats).toBe(csp)
  })

  it('frame header CSP matches the meta CSP baked into email-frame.html plus frame-ancestors', () => {
    // frame-ancestors is header-only (ignored in <meta>), so the header policy
    // is the meta policy plus exactly that one directive.
    const frameHtml = readFileSync(FRAME_HTML_FILE, 'utf8')
    const metaMatch = /http-equiv="Content-Security-Policy"\s+content="([^"]+)"/.exec(frameHtml)
    expect(metaMatch).not.toBeNull()
    const headerCsp = applyHeaders(rules, '/email-frame.html').get('content-security-policy')
    expect(headerCsp).toBe(`${metaMatch?.[1] ?? ''}; frame-ancestors 'self'`)
  })
})
