// bodyTextFallback: the blank-preview bubble fallback strips what the preview
// derivation strips (port of MessageBubbleContentSource.bodyTextFallback).

import { describe, expect, it } from 'vitest'
import { bodyTextFallback } from './bodyTextFallback'

const QUOTE_ONLY_REPLY =
  'On Mon, Jan 5, 2026 at 9:00 AM Alice <alice@example.com> wrote:\n' +
  '> Can you make it?\n' +
  '> Let me know.'

describe('bodyTextFallback', () => {
  // Revert-check: bodyTextFallback (replacing it with the raw bodyText makes this fail)
  it('bodyTextFallback_quoteOnlyReply_yieldsNoText', () => {
    expect(bodyTextFallback(QUOTE_ONLY_REPLY).mainText).toBeNull()
  })

  // Revert-check: bodyTextFallback
  it('bodyTextFallback_replyAboveQuotedHistory_keepsOnlyTheReply', () => {
    const result = bodyTextFallback(`Thanks, see you there!\n\n${QUOTE_ONLY_REPLY}`)
    expect(result.mainText).toBe('Thanks, see you there!')
  })

  // Revert-check: bodyTextFallback
  it('bodyTextFallback_forwardedHeaderBlockOnly_yieldsNoText', () => {
    const forwardedOnly =
      '---------- Forwarded message ---------\n' +
      'From: Alice <alice@example.com>\n' +
      'Date: Mon, Jan 5, 2026 at 9:00 AM\n' +
      'Subject: Numbers\n' +
      'To: Bob <bob@example.com>\n\n' +
      '> The numbers are in.'
    expect(bodyTextFallback(forwardedOnly).mainText).toBeNull()
  })

  // Revert-check: bodyTextFallback (the extractHtmlFromRawSource branch)
  it('bodyTextFallback_rawSourceWithHtmlPart_processesTheHtmlPart', () => {
    const rawSource =
      'Content-Type: multipart/alternative; boundary="b1"\n' +
      'MIME-Version: 1.0\n\n' +
      '--b1\n' +
      'Content-Type: text/html; charset=utf-8\n\n' +
      '<p>Hello <b>there</b></p>\n' +
      '--b1--\n'
    expect(bodyTextFallback(rawSource).mainText).toBe('Hello there')
  })

  it('bodyTextFallback_plainReply_passesThrough', () => {
    expect(bodyTextFallback('Sounds good.').mainText).toBe('Sounds good.')
  })
})
