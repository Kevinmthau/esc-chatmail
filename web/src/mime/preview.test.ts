import { describe, expect, it } from 'vitest'
import {
  createChatPreviewText,
  createCleanSnippet,
  createCleanedSnippet,
  indicatesForwarding,
  isForwardedSubject,
  prepareHtmlForSnippet,
} from './preview'

describe('createCleanedSnippet', () => {
  it('prefers cleaned HTML content', () => {
    const snippet = createCleanedSnippet(
      '<div>New content here.</div><div class="gmail_quote"><blockquote>Old quoted</blockquote></div>',
      'plain fallback',
      'snippet fallback',
    )
    expect(snippet).toBe('New content here.')
  })

  it('drops hidden preheaders and head metadata from snippets', () => {
    const snippet = createCleanedSnippet(
      '<html><head><title>Metadata Title</title></head><body><div style="display:none">Preheader teaser</div><div>Visible body.</div></body></html>',
      null,
      null,
    )
    expect(snippet).toBe('Visible body.')
  })

  it('falls back to plain text, then the Gmail snippet', () => {
    expect(createCleanedSnippet(null, 'Plain body text.', 'gmail snippet')).toBe('Plain body text.')
    expect(createCleanedSnippet(null, null, 'gmail snippet')).toBe('gmail snippet')
    expect(createCleanedSnippet(null, null, null)).toBeNull()
  })
})

describe('createChatPreviewText', () => {
  it('uses the HTML bubble pipeline first', () => {
    expect(createChatPreviewText('<div>Hello!</div>', 'plain', 'snippet')).toBe('Hello!')
  })

  it('falls back to plain text and snippet', () => {
    expect(createChatPreviewText(null, 'Plain here.', 'snippet')).toBe('Plain here.')
    expect(createChatPreviewText(null, null, 'Snippet here.')).toBe('Snippet here.')
    expect(createChatPreviewText(null, null, null)).toBeNull()
  })

  it('keeps forwarded content for outgoing forwards', () => {
    const forwardedPlain =
      'FYI\n\n---------- Forwarded message ---------\nFrom: someone@example.com'
    // Outgoing forward: keep plain-text handling (which truncates at the marker).
    expect(createChatPreviewText('<div>html</div>', forwardedPlain, null, true)).toBe('FYI')
  })
})

describe('createCleanSnippet', () => {
  it('collapses whitespace and strips quotes', () => {
    expect(createCleanSnippet('Hello\n\nworld\n\n> quoted line\n> more quote')).toBe('Hello world')
  })

  it('supports first-sentence extraction', () => {
    expect(createCleanSnippet('First sentence. Second sentence.', 5000, true)).toBe(
      'First sentence.',
    )
  })

  it('truncates at maxLength', () => {
    expect(createCleanSnippet('abcdef', 3)).toBe('abc...')
  })
})

describe('forwarding heuristics', () => {
  it('detects forwarded subjects', () => {
    expect(isForwardedSubject('Fwd: hello')).toBe(true)
    expect(isForwardedSubject('FW: hello')).toBe(true)
    expect(isForwardedSubject('Re: hello')).toBe(false)
    expect(isForwardedSubject(null)).toBe(false)
  })

  it('detects forward markers in content', () => {
    expect(indicatesForwarding(null, ['---------- Forwarded message ---------'])).toBe(true)
    expect(indicatesForwarding(null, ['Begin forwarded message:'])).toBe(true)
    expect(indicatesForwarding(null, ['just regular text'])).toBe(false)
  })
})

describe('prepareHtmlForSnippet', () => {
  it('removes head, comments, and hidden elements', () => {
    const html =
      '<head><title>T</title></head><!--[if mso]>x<![endif]--><span style="display:none">hidden</span><div>keep</div>'
    const prepared = prepareHtmlForSnippet(html)
    expect(prepared).not.toContain('T</title>')
    expect(prepared).not.toContain('hidden')
    expect(prepared).toContain('keep')
  })
})
