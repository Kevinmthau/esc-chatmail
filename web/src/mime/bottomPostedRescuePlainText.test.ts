// Port of the bottom-posted reply cases in PlainTextQuoteRemoverTests.swift.
import { describe, expect, it } from 'vitest'
import { processChatBubbleText } from './bubble'
import { extractQuotes, removeQuotes } from './text'

describe('extractQuotes bottom-posted rescue', () => {
  // Revert-check: bottomPostedRescue (text.ts)
  it('removeQuotes, bottom-posted reply after a quote block, recovers the reply as content', () => {
    const text = [
      'On Aug 1, 2026, at 9:00 AM, Olga Smith <olga@example.com> wrote:',
      '',
      '> Are you free for lunch tomorrow?',
      '> We could try the new place.',
      '',
      'Yes! Tomorrow at noon works great for me.',
      'See you there.',
    ].join('\n')

    expect(removeQuotes(text)).toBe('Yes! Tomorrow at noon works great for me.\nSee you there.')
  })

  // Revert-check: bottomPostedRescue (text.ts) returning `remainingQuotedRegion`
  it('extractQuotes, bottom-posted reply, recovered text is not duplicated in the quoted part', () => {
    const text = [
      'On Aug 1, 2026, at 9:00 AM, Olga Smith <olga@example.com> wrote:',
      '',
      '> Are you free for lunch tomorrow?',
      '> We could try the new place.',
      '',
      'Yes! Tomorrow at noon works great for me.',
    ].join('\n')

    const result = extractQuotes(text)
    expect(result.mainContent).toBe('Yes! Tomorrow at noon works great for me.')
    expect(result.quotedParts).toHaveLength(1)
    const quoted = result.quotedParts[0]!.text
    expect(quoted).toContain('Are you free for lunch tomorrow?')
    expect(quoted).toContain('We could try the new place.')
    expect(quoted).not.toContain('Yes! Tomorrow at noon works great for me.')
  })

  // Revert-check: bottomPostedRescue (text.ts) anchoring on the LAST ">" line
  it('extractQuotes, interleaved inline replies, recovers only the trailing segment', () => {
    // Documented limitation: only the segment after the LAST ">" line is
    // recovered as the reply bubble. Earlier inline answers stay inside
    // the quoted part, interleaved next to the lines they answer, and
    // must not also leak into the recovered main content.
    const text = [
      'On Aug 1, 2026, at 9:00 AM, Olga Smith <olga@example.com> wrote:',
      '',
      '> Are you free Tuesday?',
      'Tuesday works for me.',
      '> Should we invite Sam?',
      'Yes, definitely invite Sam.',
    ].join('\n')

    const result = extractQuotes(text)
    expect(result.mainContent).toBe('Yes, definitely invite Sam.')
    expect(result.quotedParts).toHaveLength(1)
    const quoted = result.quotedParts[0]!.text
    expect(quoted).toContain('Are you free Tuesday?')
    expect(quoted).toContain('Tuesday works for me.')
    expect(quoted).toContain('Should we invite Sam?')
    expect(quoted).not.toContain('Yes, definitely invite Sam.')
  })

  // Revert-check: bottomPostedRescue (text.ts) dropping attribution and header lines
  it('extractQuotes, quote-first region whose tail is only headers, recovers nothing', () => {
    const text = [
      '> Are you free for lunch tomorrow?',
      '> We could try the new place.',
      '',
      'On Aug 1, 2026, at 9:00 AM, Olga Smith <olga@example.com> wrote:',
      'From: Olga Smith <olga@example.com>',
    ].join('\n')

    const result = extractQuotes(text)
    expect(result.mainContent).toBe('')
    expect(result.quotedParts).toHaveLength(1)
    expect(result.quotedParts[0]!.text).toContain('Are you free for lunch tomorrow?')
  })

  // Revert-check: bottomPostedRescue (text.ts) through processPlainText
  it('processChatBubbleText, plain-text bottom-posted reply, shows the reply in the bubble', () => {
    const text = [
      'On Aug 1, 2026, at 9:00 AM, Olga Smith <olga@example.com> wrote:',
      '',
      '> Are you free for lunch tomorrow?',
      '> We could try the new place.',
      '',
      'Yes! Tomorrow at noon works great for me.',
      'See you there.',
    ].join('\n')

    const result = processChatBubbleText(text, { inputKind: 'plainText' })
    // Line unwrapping runs before extraction, so compare on words, not breaks.
    expect(result.mainText?.replace(/\s+/g, ' ')).toBe(
      'Yes! Tomorrow at noon works great for me. See you there.',
    )
    expect(result.quotedParts).toHaveLength(1)
    expect(result.quotedParts[0]!.text).not.toContain('Yes! Tomorrow at noon')
  })
})
