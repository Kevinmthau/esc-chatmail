import { describe, expect, it } from 'vitest'
import { normalizeEmail } from './normalizeEmail'
import { calculateParticipantHash, makeParticipantSetIdentity } from './participantSet'

// Unicode parity with EmailNormalizer.normalize
// (`trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`), whose
// output is hashed into the cross-platform participantHash. The digests
// were produced by running the Swift source on the same inputs and agree
// with `printf 'p|<key>' | shasum -a 256`.
//
// Revert-check: normalizeEmail's trimSwiftWhitespaceAndNewlines and
// lowercasePerCodePoint. Back on `raw.trim().toLowerCase()`, the sigma case
// yields 'σας' (Final_Sigma), the BOM is stripped and the NEL is kept.

describe('normalizeEmail Swift parity', () => {
  it('lowercases a word-final capital sigma to σ, not the Final_Sigma ς', () => {
    expect(normalizeEmail('ΣΑΣ@x.com')).toBe('σασ@x.com')
    expect(calculateParticipantHash([normalizeEmail('ΣΑΣ@x.com')])).toBe(
      'de34f2ba1baff7e82a383c97367728a0274a07b54f2b4ec59b742f86144f347b',
    )
  })

  it('keeps a leading U+FEFF, which Swift does not count as whitespace', () => {
    expect(normalizeEmail('﻿alice@x.com')).toBe('﻿alice@x.com')
    expect(calculateParticipantHash([normalizeEmail('﻿alice@x.com')])).toBe(
      '702ffd67932d094e17b127a5a3ca461ec94f9b0a70c7dc627c27a12f85f1e488',
    )
  })

  it('strips U+0085 NEL, which Swift counts as a newline', () => {
    expect(normalizeEmail('\u0085alice@x.com\u0085')).toBe('alice@x.com')
    expect(calculateParticipantHash([normalizeEmail('\u0085alice@x.com')])).toBe(
      'cf079aa67a2ccd66d00ae041f0128a0ef1fbaca629c89eda9407fc6733476a8f',
    )
  })

  it.each([
    [' alice@x.com ', 'NBSP'],
    ['　alice@x.com ', 'ideographic space / line separator'],
    ['\t\v\f\r\nalice@x.com  ', 'ASCII controls / paragraph separator'],
    [' alice@x.com ', 'en quad / medium mathematical space'],
  ])('strips Swift whitespace-and-newlines on both ends: %j (%s)', (raw) => {
    expect(normalizeEmail(raw)).toBe('alice@x.com')
  })

  it('does not strip a zero-width space, which is Cf, not Z', () => {
    expect(normalizeEmail('​alice@x.com')).toBe('​alice@x.com')
  })

  it('preserves the scalars it was given: a decomposed accent is not composed', () => {
    // Swift hashes the scalars as received (the golden corpus case
    // unicode_combining_scalar_sort pins the decomposed form), so this must
    // not NFC-normalize even though Swift equality is canonical.
    const decomposed = 'étudiant@x.fr'
    expect(normalizeEmail(decomposed)).toBe(decomposed)
    expect(normalizeEmail('Étudiant@x.fr')).toBe('étudiant@x.fr')
    // printf 'p|z@x.com|e\xcc\x81tudiant@x.fr' | shasum -a 256
    const identity = makeParticipantSetIdentity(
      new Set([decomposed, 'z@x.com'].map(normalizeEmail)),
      new Set(),
    )
    expect(identity.participants).toEqual(['z@x.com', decomposed])
    expect(identity.participantHash).toBe(
      '11a44aa115d87379898b788a2de450d3984f23890b615bb2f26bda3cb6f8e7eb',
    )
  })

  it('gmail canonicalization still applies after the Unicode steps', () => {
    expect(normalizeEmail('\u0085J.O.H.N+Tag@GMAIL.com　')).toBe('john@gmail.com')
  })
})
