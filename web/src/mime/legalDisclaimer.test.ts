// Pins legalDisclaimer.ts, the classifier behind the trailing-disclaimer passes of
// html.ts and signature.ts. Mirrors iOS LegalDisclaimerPolicyTests; the golden corpus
// pins what the bubble shows.

import { describe, expect, it } from 'vitest'
import { removeQuotesFromHtml } from './html'
import {
  isLegalDisclaimer,
  legalDisclaimerClauses,
  trailingLegalDisclaimerStartLine,
} from './legalDisclaimer'

// The Front transport footer that leaked (2026-11-17), with the company renamed.
const ADDRESSEE_DISCLAIMER =
  'This communication is the property of Northwind and its affiliates; it is confidential and ' +
  'intended solely for the use of the addressee(s). We expressly disclaim any reliance on or use of ' +
  'this communication by anyone else. If you are not an addressee, please notify the sender and delete ' +
  'this message immediately from your computer, computing device, and/or all related systems and data storage.'

describe('legalDisclaimerClauses / isLegalDisclaimer', () => {
  // Revert-check: CLAUSE_PATTERNS misdirectedReader "an? … addressee".
  it('names every kind of clause in the addressee wording', () => {
    expect([...legalDisclaimerClauses(ADDRESSEE_DISCLAIMER)].sort()).toEqual(
      [
        'confidentiality',
        'deleteMessage',
        'intendedReader',
        'misdirectedReader',
        'notifySender',
        'prohibition',
      ].sort(),
    )
    expect(isLegalDisclaimer(ADDRESSEE_DISCLAIMER)).toBe(true)
  })

  it('reads received-in-error wordings as a misdirected reader', () => {
    for (const text of [
      'If you have received this e-mail in error, please delete it.',
      'If you believe you received this message by mistake, tell us.',
      'If you aren’t the intended recipient, stop reading.',
    ]) {
      expect(legalDisclaimerClauses(text).has('misdirectedReader'), text).toBe(true)
    }
  })

  // Revert-check: the misdirectedReader || intendedReader guard in isLegalDisclaimer.
  it('needs a statement of the reader', () => {
    const text =
      'This confidential plan must not be forwarded; unauthorized copies are prohibited, so delete the attachments.'
    expect([...legalDisclaimerClauses(text)].sort()).toEqual(
      ['confidentiality', 'deleteMessage', 'prohibition'].sort(),
    )
    expect(isLegalDisclaimer(text)).toBe(false)
  })

  // Revert-check: the size >= 3 floor in isLegalDisclaimer.
  it('needs more than two clauses', () => {
    for (const text of [
      'CONFIDENTIALITY NOTICE: This e-mail and any attachments are for the exclusive use of the intended recipient.',
      'Confidentiality notice: remove the intended recipient clause and the word confidential.',
      'This email may contain confidential information. Please forward it to counsel.',
    ]) {
      expect(isLegalDisclaimer(text), text).toBe(false)
    }
  })
})

describe('trailingLegalDisclaimerStartLine', () => {
  it('starts at a disclaimer after the sign-off', () => {
    const lines = [
      'Please find the summary attached.',
      '',
      'Thanks',
      'Robin',
      '',
      ADDRESSEE_DISCLAIMER,
    ]
    expect(trailingLegalDisclaimerStartLine(lines)).toBe(5)
  })

  // Revert-check: belongsToDisclaimer's two-clause floor.
  it('leaves an authored one-clause line above the disclaimer', () => {
    const lines = ['Here is the draft.', 'Please keep this confidential.', ADDRESSEE_DISCLAIMER]
    expect(trailingLegalDisclaimerStartLine(lines)).toBe(2)
  })

  // Revert-check: opensDisclaimer, where trailingLegalDisclaimerStartLine starts the run.
  it('leaves an authored two-clause line above the disclaimer', () => {
    for (const authored of [
      'Please keep this confidential and delete the attachments after review.',
      'Please delete the old messages and notify us when done.',
      'Unauthorized access to the confidential folder was flagged.',
    ]) {
      expect(legalDisclaimerClauses(authored).size, authored).toBe(2)
      const lines = ['Hi team,', '', authored, '', ADDRESSEE_DISCLAIMER]
      expect(trailingLegalDisclaimerStartLine(lines), authored).toBe(4)
    }
  })

  it('keeps a disclaimer opening that names two clauses but not the reader', () => {
    const lines = [
      'Reply.',
      '',
      'This email is confidential and may be privileged. Unauthorized use is prohibited.',
      '',
      'If you are not the intended recipient, please notify the sender and delete this message.',
    ]
    expect(trailingLegalDisclaimerStartLine(lines)).toBe(4)
  })

  it('takes a heading and an environment footer with the disclaimer', () => {
    const lines = [
      'Reply.',
      '',
      'CONFIDENTIALITY NOTICE:',
      ADDRESSEE_DISCLAIMER,
      '',
      'Please consider the environment before printing this e-mail.',
    ]
    expect(trailingLegalDisclaimerStartLine(lines)).toBe(2)
  })

  // Revert-check: POSTSCRIPT_PATTERN.
  it('takes nothing when a postscript follows', () => {
    const lines = [
      'Here is the draft.',
      '',
      ADDRESSEE_DISCLAIMER,
      '',
      'P.S. The confidential copy is attached.',
    ]
    expect(trailingLegalDisclaimerStartLine(lines)).toBeNull()
  })

  // Revert-check: the runStart > 1 bound.
  it('takes nothing when the disclaimer is the whole message', () => {
    expect(trailingLegalDisclaimerStartLine([ADDRESSEE_DISCLAIMER])).toBeNull()
    expect(trailingLegalDisclaimerStartLine(['', ADDRESSEE_DISCLAIMER, ''])).toBeNull()
  })

  // Revert-check: continuesParagraph.
  it('starts a hard-wrapped disclaimer at its first line', () => {
    const lines = [
      'Thanks,',
      'Robin',
      '',
      'This communication is the property of Northwind and its affiliates; it is',
      'confidential and intended solely for the use of the addressee(s). If you',
      'are not an addressee, please notify the sender and delete this message.',
    ]
    expect(trailingLegalDisclaimerStartLine(lines)).toBe(3)
  })

  it('leaves a sign-off with no blank line above the disclaimer', () => {
    const lines = ['Please find the summary attached.', 'Thanks', 'Robin', ADDRESSEE_DISCLAIMER]
    expect(trailingLegalDisclaimerStartLine(lines)).toBe(3)
  })

  it('takes nothing when the last paragraph names no clause', () => {
    const lines = [
      'Reply.',
      '',
      ADDRESSEE_DISCLAIMER,
      '',
      'Email cannot be guaranteed to be secure or error-free.',
    ]
    expect(trailingLegalDisclaimerStartLine(lines)).toBeNull()
  })
})

// Mirrors iOS EmailDOMLegalDisclaimerTests.
describe('removeQuotesFromHtml trailing legal disclaimer guards', () => {
  const disclaimer =
    'This communication is confidential and intended solely for the use of the addressee(s). ' +
    'If you are not an addressee, please notify the sender and delete this message.'

  // Revert-check: the containsMediaAfterSignature guard in truncateTrailingLegalDisclaimer.
  it('keeps the disclaimer and an authored image after it', () => {
    const html = `<p>Here are the photos.</p><p>${disclaimer}</p><p><img src="cid:photo" width="1600" height="1200"></p>`
    const cleaned = removeQuotesFromHtml(html) ?? ''
    expect(cleaned).toContain('cid:photo')
    expect(cleaned).toContain('If you are not an addressee')
  })

  it('removes the disclaimer before a tracking pixel', () => {
    const html =
      `<p>Here are the photos.</p><p>${disclaimer}</p>` +
      '<img src="https://t.example/p.gif" width="1" height="1" aria-hidden="true">'
    const cleaned = removeQuotesFromHtml(html) ?? ''
    expect(cleaned).toContain('Here are the photos.')
    expect(cleaned).not.toContain('addressee')
  })

  it('keeps the disclaimer in quotedOnly mode', () => {
    const html = `<p>Reply.</p><p>${disclaimer}</p>`
    expect(removeQuotesFromHtml(html) ?? '').not.toContain('addressee')
    expect(removeQuotesFromHtml(html, 'quotedOnly') ?? '').toContain('addressee')
  })

  it('keeps a disclaimer that is the whole message', () => {
    expect(removeQuotesFromHtml(`<p>${disclaimer}</p>`) ?? '').toContain('addressee')
  })

  it('keeps the authored line above a break in the same block', () => {
    const cleaned =
      removeQuotesFromHtml(`<div>Thanks for the update.<br><br>${disclaimer}</div>`) ?? ''
    expect(cleaned).toContain('Thanks for the update.')
    expect(cleaned).not.toContain('addressee')
  })
})
