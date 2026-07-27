// Golden-corpus replay for the MIME text-processing pipeline. Mirrors the
// iOS GoldenCorpusReplayTests entry points for the four sections owned by
// this module. The corpus JSON is imported from the iOS test fixtures — it is
// the single source of truth and must never be weakened.

import { describe, expect, it } from 'vitest'
import corpusJson from '@fixtures/golden_message_corpus.json'
import { processChatBubbleText } from './bubble'
import { calculateNewsletterScore } from './newsletter'
import { extractHtmlFromRawSource } from './rawSource'

interface PlainTextQuoteCleanupCase {
  id: string
  input: string
  expected: string
  notes?: string
}

interface HtmlToBubbleTextCase {
  id: string
  inputHTML: string
  expected: string
  notes?: string
}

interface RawSourceHtmlRecoveryCase {
  id: string
  input: string
  expectedHTMLContains: string
  expectedTextContains: string
  expectedHasRichHTMLContent: boolean
  notes?: string
}

interface NewsletterDetectionCase {
  id: string
  labelIds?: string[]
  from?: string
  replyTo?: string
  subject?: string
  listUnsubscribe?: string
  listUnsubscribePost?: string
  listId?: string
  precedence?: string
  toCount?: number
  ccCount?: number
  expectedIsNewsletter: boolean
  expectedScore?: number
  notes?: string
}

interface GoldenCorpus {
  plainTextQuoteCleanupCases: PlainTextQuoteCleanupCase[]
  htmlToBubbleTextCases: HtmlToBubbleTextCase[]
  rawSourceHTMLRecoveryCases: RawSourceHtmlRecoveryCase[]
  newsletterDetectionCases: NewsletterDetectionCase[]
}

const corpus = corpusJson as unknown as GoldenCorpus

function normalize(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim()
}

describe('golden corpus: plainTextQuoteCleanupCases', () => {
  it.each(corpus.plainTextQuoteCleanupCases.map((c) => [c.id, c] as const))(
    '%s',
    (_id, scenario) => {
      const result = processChatBubbleText(scenario.input, {
        inputKind: 'plainText',
        sanitizeRawEmailSource: true,
        decodeHTMLEntities: true,
        formatSignOffLineBreaks: true,
        classifyRichContent: false,
      })
      expect(normalize(result.mainText ?? ''), scenario.notes).toBe(normalize(scenario.expected))
    },
  )
})

describe('golden corpus: htmlToBubbleTextCases', () => {
  it.each(corpus.htmlToBubbleTextCases.map((c) => [c.id, c] as const))('%s', (_id, scenario) => {
    const result = processChatBubbleText(scenario.inputHTML, {
      inputKind: 'html',
      sanitizeRawEmailSource: false,
      decodeHTMLEntities: true,
      formatSignOffLineBreaks: true,
      classifyRichContent: false,
    })
    expect(normalize(result.mainText ?? ''), scenario.notes).toBe(normalize(scenario.expected))
  })
})

describe('golden corpus: rawSourceHTMLRecoveryCases', () => {
  it.each(corpus.rawSourceHTMLRecoveryCases.map((c) => [c.id, c] as const))(
    '%s',
    (_id, scenario) => {
      const extractedHTML = extractHtmlFromRawSource(scenario.input)
      expect(extractedHTML, scenario.notes).not.toBeNull()

      const html = extractedHTML ?? ''
      expect(normalize(html), scenario.notes).toContain(normalize(scenario.expectedHTMLContains))

      const result = processChatBubbleText(html, {
        inputKind: 'html',
        sanitizeRawEmailSource: false,
        decodeHTMLEntities: true,
        formatSignOffLineBreaks: true,
        classifyRichContent: true,
      })

      expect(result.hasRichContent, scenario.notes).toBe(scenario.expectedHasRichHTMLContent)
      expect(normalize(result.mainText ?? ''), scenario.notes).toContain(
        normalize(scenario.expectedTextContains),
      )
    },
  )
})

describe('golden corpus: newsletterDetectionCases', () => {
  it.each(corpus.newsletterDetectionCases.map((c) => [c.id, c] as const))('%s', (_id, scenario) => {
    const result = calculateNewsletterScore(scenario.labelIds ?? [], {
      from: scenario.from ?? null,
      replyTo: scenario.replyTo ?? null,
      subject: scenario.subject ?? null,
      listUnsubscribe: scenario.listUnsubscribe ?? null,
      listUnsubscribePost: scenario.listUnsubscribePost ?? null,
      listId: scenario.listId ?? null,
      precedence: scenario.precedence ?? null,
      toCount: scenario.toCount ?? 0,
      ccCount: scenario.ccCount ?? 0,
    })

    expect(result.isNewsletter, scenario.notes).toBe(scenario.expectedIsNewsletter)
    if (scenario.expectedScore !== undefined) {
      expect(result.score, scenario.notes).toBe(scenario.expectedScore)
    }
  })
})
