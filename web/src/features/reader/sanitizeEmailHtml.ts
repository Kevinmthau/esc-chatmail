// DOMPurify sanitation pipeline for email HTML (security-critical).
//
// Sanitization here is the PRIMARY defense; the sandboxed opaque-origin
// email-frame with its own CSP is defense in depth. The output is a full,
// self-contained HTML document string carrying its own meta CSP and base
// styles, plus the list of cid: image ids the caller must resolve to Blobs.

export type EmailRenderMode = 'preview' | 'full'

export interface SanitizedEmailHtml {
  html: string
  /** Content-IDs referenced by inline images, angle brackets stripped. */
  cids: string[]
}

const FORBID_TAGS = [
  'script',
  'iframe',
  'object',
  'embed',
  'form',
  'base',
  'link',
  'meta',
  'audio',
  'video',
  'math',
  'template',
  'slot',
]

const FORBID_ATTR = ['formaction', 'xlink:href', 'ping']

// DOMPurify tests ALLOWED_URI_REGEXP against the value of EVERY kept
// attribute that is not in its URI_SAFE_ATTRIBUTES set (width, bgcolor,
// align, colspan, SVG geometry, ...), not just URI attributes — so the
// pattern must also accept plain non-URI values or table-email layout is
// destroyed. This mirrors the structure of DOMPurify's default
// IS_ALLOWED_URI: an explicit scheme allowlist, then the non-URI alternation
// — a value starting with a non-letter ("600", "#fff", "#anchor") or a word
// NOT followed by ':' ("center", "images/logo.png"). Anything shaped like an
// unlisted `scheme:` (javascript:, vbscript:, data:) is rejected. data: is
// deliberately absent from the allowlist: DOMPurify's separate DATA_URI_TAGS
// branch still admits data: URIs on <img src>, while data:text/html links
// are dropped.
const ALLOWED_URI_REGEXP = /^(?:(?:https?|mailto|tel|cid):|[^a-z]|[a-z+.-]+(?:[^a-z+.:-]|$))/i

const CSP_CONTENT =
  "default-src 'none'; img-src https: http: data: blob: cid:; " +
  "style-src 'unsafe-inline'; font-src https: data:"

const BASE_STYLE =
  ':root{color-scheme:light only}' +
  'body{margin:0;background:#fff;color:#111;' +
  'font:15px/1.45 -apple-system,system-ui,sans-serif;overflow-wrap:break-word}' +
  'img{max-width:100%;height:auto}'

const PREVIEW_STYLE = 'html,body{overflow:hidden}'

let purifyPromise: Promise<typeof import('dompurify').default> | null = null

function loadPurify(): Promise<typeof import('dompurify').default> {
  purifyPromise ??= import('dompurify').then((m) => m.default)
  return purifyPromise
}

/** Strips angle brackets/whitespace from a Content-ID. */
function normalizeCid(rawCid: string): string {
  return rawCid.replace(/[<>]/g, '').trim()
}

export async function sanitizeEmailHtml(
  rawHtml: string,
  opts: { mode: EmailRenderMode },
): Promise<SanitizedEmailHtml> {
  const purify = await loadPurify()

  const node: Node = purify.sanitize(rawHtml, {
    WHOLE_DOCUMENT: true,
    RETURN_DOM: true,
    FORBID_TAGS,
    FORBID_ATTR,
    ALLOWED_URI_REGEXP,
  })

  // RETURN_DOM + WHOLE_DOCUMENT yields the sanitized document (or its root
  // element, depending on version) inside DOMPurify's private document —
  // never the live app document.
  const doc =
    node.nodeType === Node.DOCUMENT_NODE ? (node as Document) : (node as Element).ownerDocument
  if (doc === null) throw new Error('sanitizeEmailHtml: sanitizer returned a detached node')
  const root = doc.documentElement
  if (root === null) throw new Error('sanitizeEmailHtml: sanitized document has no root')

  // Collect + normalize cid: image references. Images whose cid is empty
  // after normalization can never resolve; drop their src outright.
  const cids: string[] = []
  for (const img of Array.from(root.querySelectorAll('img'))) {
    const src = img.getAttribute('src') ?? ''
    if (!/^cid:/i.test(src)) continue
    const cid = normalizeCid(src.slice(4))
    if (cid.length === 0) {
      img.removeAttribute('src')
      continue
    }
    img.setAttribute('src', `cid:${cid}`)
    if (!cids.includes(cid)) cids.push(cid)
  }

  // Every link opens outside the frame and never leaks referrer/opener.
  for (const anchor of Array.from(root.querySelectorAll('a'))) {
    anchor.setAttribute('target', '_blank')
    anchor.setAttribute('rel', 'noopener noreferrer')
  }

  let head = root.querySelector('head')
  if (head === null) {
    head = doc.createElement('head')
    root.insertBefore(head, root.firstChild)
  }

  const meta = doc.createElement('meta')
  meta.setAttribute('http-equiv', 'Content-Security-Policy')
  meta.setAttribute('content', CSP_CONTENT)
  head.insertBefore(meta, head.firstChild)

  const style = doc.createElement('style')
  style.textContent = opts.mode === 'preview' ? BASE_STYLE + PREVIEW_STYLE : BASE_STYLE
  head.appendChild(style)

  // HTML serialization, never XMLSerializer: the frame (public/email-frame.js)
  // re-parses this string with DOMParser('text/html'), where <style> is raw
  // text and character references are not decoded. XML serialization escapes
  // '&'/'<'/'>' inside every text node INCLUDING <style>, so the round-trip
  // would hand the CSS parser literal '&gt;'/'&amp;' — silently breaking child
  // combinators and url() query strings. outerHTML uses the HTML fragment
  // serialization algorithm, which leaves raw-text children intact and never
  // self-closes non-void elements.
  return { html: `<!doctype html>${root.outerHTML}`, cids }
}
