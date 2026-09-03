// Golden-corpus replay for the message display policy and rich-HTML detection.
// Mirrors the iOS GoldenCorpusReplayTests entry points: displayPolicyCases run
// against the MessageDisplayPolicy port, richHTMLDetectionCases against the
// ProcessedTextCache.processMessage path (htmlCompatibilityFallback with
// classifyRichContent, which routes through hasGenuineRichContent).

import { describe, expect, it } from 'vitest'
import corpusJson from '@fixtures/golden_message_corpus.json'
import { htmlCompatibilityFallback } from '@/mime/bubble'
import {
  isTrustedTransactionalSender,
  messageDisplayMode,
  normalizedSourceDomain,
  shouldShowHtmlPreview,
} from './displayPolicy'

interface DisplayPolicyCase {
  id: string
  hasHTMLSource: boolean
  isForwardedEmail: boolean
  isNewsletter: boolean
  hasRichHTMLContent: boolean
  isFromMe: boolean
  isLikelyCalendarInvite?: boolean
  isOneToOneConversation: boolean
  subject?: string | null
  senderEmail?: string | null
  expectedShowHTMLPreview: boolean
  notes?: string
}

interface RichHtmlDetectionCase {
  id: string
  inputHTML: string
  expectedHasRichHTMLContent: boolean
  notes?: string
}

interface GoldenCorpus {
  displayPolicyCases: DisplayPolicyCase[]
  richHTMLDetectionCases: RichHtmlDetectionCase[]
}

const corpus = corpusJson as unknown as GoldenCorpus

describe('golden corpus: displayPolicyCases', () => {
  it('has cases', () => {
    expect(corpus.displayPolicyCases.length).toBeGreaterThan(0)
  })

  it.each(corpus.displayPolicyCases.map((c) => [c.id, c] as const))('%s', (_id, scenario) => {
    const input = {
      hasHTMLSource: scenario.hasHTMLSource,
      isForwardedEmail: scenario.isForwardedEmail,
      isNewsletter: scenario.isNewsletter,
      hasRichHTMLContent: scenario.hasRichHTMLContent,
      isFromMe: scenario.isFromMe,
      isLikelyCalendarInvite: scenario.isLikelyCalendarInvite ?? false,
      isOneToOneConversation: scenario.isOneToOneConversation,
      subject: scenario.subject ?? null,
      senderEmail: scenario.senderEmail ?? null,
    }
    expect(shouldShowHtmlPreview(input), scenario.notes).toBe(scenario.expectedShowHTMLPreview)
    expect(messageDisplayMode(input), scenario.notes).toBe(
      scenario.expectedShowHTMLPreview ? 'previewCard' : 'textBubble',
    )
  })
})

describe('golden corpus: richHTMLDetectionCases', () => {
  it('has cases', () => {
    expect(corpus.richHTMLDetectionCases.length).toBeGreaterThan(0)
  })

  it.each(corpus.richHTMLDetectionCases.map((c) => [c.id, c] as const))('%s', (_id, scenario) => {
    const result = htmlCompatibilityFallback(scenario.inputHTML, true)
    expect(result.hasRichContent, scenario.notes).toBe(scenario.expectedHasRichHTMLContent)
  })
})

describe('trusted transactional sender anchoring', () => {
  it('accepts exact and subdomain matches of trusted suffixes', () => {
    expect(isTrustedTransactionalSender('relay@members.ebay.com')).toBe(true)
    expect(isTrustedTransactionalSender('notify@hello.bill.com')).toBe(true)
    expect(isTrustedTransactionalSender('"Amazon" <ship-confirm@amazon.com>')).toBe(true)
  })

  it('rejects suffix spoofs and display-name forgeries', () => {
    expect(isTrustedTransactionalSender('a@members.ebay.com.evil.com')).toBe(false)
    expect(isTrustedTransactionalSender('a@notamazon.com')).toBe(false)
    expect(isTrustedTransactionalSender('"relay@members.ebay.com" <a@evil.com>')).toBe(false)
    expect(isTrustedTransactionalSender(null)).toBe(false)
    expect(isTrustedTransactionalSender('')).toBe(false)
  })

  it('normalizes sender domains like the iOS PreviewTextUtilities', () => {
    expect(normalizedSourceDomain('Person <a@WWW.Example.COM>')).toBe('example.com')
    expect(normalizedSourceDomain('a@')).toBeNull()
    expect(normalizedSourceDomain('no-at-sign')).toBeNull()
    expect(normalizedSourceDomain('   ')).toBeNull()
  })
})

describe('branches not covered by the corpus', () => {
  const base = {
    hasHTMLSource: true,
    isForwardedEmail: false,
    isNewsletter: false,
    hasRichHTMLContent: false,
    isFromMe: false,
    isOneToOneConversation: false,
    subject: 'Team offsite',
    senderEmail: 'person@example.com',
  }

  it('calendar invites show the preview card', () => {
    expect(shouldShowHtmlPreview({ ...base, isLikelyCalendarInvite: true })).toBe(true)
    expect(shouldShowHtmlPreview({ ...base, isLikelyCalendarInvite: false })).toBe(false)
  })

  it('forwarded mail from me stays a bubble', () => {
    expect(shouldShowHtmlPreview({ ...base, isForwardedEmail: true, isFromMe: true })).toBe(false)
  })

  it('newsletter without HTML source still routes to preview (recovery path)', () => {
    expect(shouldShowHtmlPreview({ ...base, hasHTMLSource: false, isNewsletter: true })).toBe(true)
  })
})
