import { describe, expect, it } from 'vitest'
import { isContactSignatureLine } from './html'
import {
  ADDRESS_KEYWORD_PATTERN,
  SIGNATURE_NAME_CONTACT_WORD_PATTERN,
  isStrongSignatureSupportLine,
  shouldPreserveSignatureNameLine,
} from './patterns'
import { removeSignature } from './signature'
import { looksLikeNameLine } from './text'

// iOS evaluates these keyword classifiers under ICU, whose `\b` treats "ë", "é"
// and "ñ" as word characters. JavaScript's `\b` is ASCII-only, so "Noël" used to
// match `\bno\b`, "Iñaki" `^i\b`, "Letícia" `^let\b` and "Stéphane" `\bst\b`.
// Revert-check: patterns.ts WORD_START / WORD_END (ICU_WORD_CHARACTER) and the
// `u`-flag RegExp constructors built from them; signature.ts
// AUTHORED_PROSE_PREFIX_PATTERN / BODY_PROSE_COMPANY_SUFFIX_PATTERN.

describe('isStrongSignatureSupportLine with accented names', () => {
  it('isStrongSignatureSupportLine_noelTitleLine_isTitle', () => {
    expect(isStrongSignatureSupportLine('Noël Dupont | Sales Director')).toBe(true)
  })

  it('isStrongSignatureSupportLine_inakiTitleLine_isTitle', () => {
    expect(isStrongSignatureSupportLine('Iñaki García | Sales Manager')).toBe(true)
  })

  it('isStrongSignatureSupportLine_zoeTitleLine_isTitle', () => {
    // HONEST SCOPE: "Zoë" starts with no keyword, so this line already passed
    // under ASCII `\b`; it pins that the ICU boundary keeps it a title.
    expect(isStrongSignatureSupportLine('Zoë Martin | Vice President')).toBe(true)
  })

  it('isStrongSignatureSupportLine_asciiNameTitleLine_isTitle', () => {
    expect(isStrongSignatureSupportLine('Nora Dupont | Sales Director')).toBe(true)
  })

  it('isStrongSignatureSupportLine_instructionNamingRole_isProse', () => {
    // The ASCII keywords still bound on ASCII punctuation and spaces.
    expect(isStrongSignatureSupportLine('DO NOT PAY THE CONSULTANT')).toBe(false)
    expect(isStrongSignatureSupportLine('No payment to the director yet')).toBe(false)
    expect(isStrongSignatureSupportLine('Our manager will call')).toBe(false)
  })

  it('isStrongSignatureSupportLine_companySuffixAfterAccentedLetter_isNotBounded', () => {
    // Synthetic token: under ICU "ë" is a word character, so `\bco\.` does not
    // match inside "Mëco." and the trailing period keeps the line a sentence.
    expect(isStrongSignatureSupportLine('Director Mëco.')).toBe(false)
    expect(isStrongSignatureSupportLine('Acme Sales Co.')).toBe(true)
  })
})

describe('shouldPreserveSignatureNameLine with accented names', () => {
  it('shouldPreserveSignatureNameLine_noelTitleLine_isNotPreservedAsName', () => {
    expect(shouldPreserveSignatureNameLine('Noël Dupont, Sales Director')).toBe(false)
    expect(shouldPreserveSignatureNameLine('Noël Dupont')).toBe(true)
  })
})

describe('SIGNATURE_NAME_CONTACT_WORD_PATTERN boundary', () => {
  it('nameContactWord_keywordInsideAccentedWord_doesNotMatch', () => {
    expect(SIGNATURE_NAME_CONTACT_WORD_PATTERN.test('Céline Office')).toBe(true)
    expect(SIGNATURE_NAME_CONTACT_WORD_PATTERN.test('Officeé')).toBe(false)
    expect(looksLikeNameLine('Noël Dupont')).toBe(true)
  })
})

describe('ADDRESS_KEYWORD_PATTERN with accented names', () => {
  it('addressKeyword_stephaneNameLine_isNotAnAddress', () => {
    expect(ADDRESS_KEYWORD_PATTERN.test('Stéphane Dubois')).toBe(false)
    expect(isContactSignatureLine('Stéphane Dubois')).toBe(false)
  })

  it('addressKeyword_streetLine_isAnAddress', () => {
    expect(ADDRESS_KEYWORD_PATTERN.test('12 Rue St. Honoré')).toBe(true)
    expect(ADDRESS_KEYWORD_PATTERN.test('100 Main St')).toBe(true)
    expect(ADDRESS_KEYWORD_PATTERN.test('Suite 400')).toBe(true)
  })
})

describe('removeSignature with accented names on the [cid:]-anchored route', () => {
  const body = 'Thanks, will do.\n\n[cid:image001.png@01DA1234.5678ABCD]\n'
  const contact = '\nnoel@example.com\n415-555-0100'

  it('removeSignature_noelTitleAfterInlineImagePlaceholder_stripsPlaceholderAndSignature', () => {
    expect(removeSignature(body + 'Noël Dupont | Sales Director' + contact)).toBe(
      'Thanks, will do.',
    )
  })

  it('removeSignature_inakiTitleAfterInlineImagePlaceholder_stripsPlaceholderAndSignature', () => {
    expect(removeSignature(body + 'Iñaki García | Sales Director' + contact)).toBe(
      'Thanks, will do.',
    )
  })

  it('removeSignature_leticiaTitleAfterInlineImagePlaceholder_stripsPlaceholderAndSignature', () => {
    expect(removeSignature(body + 'Letícia Souza | Sales Director' + contact)).toBe(
      'Thanks, will do.',
    )
  })

  it('removeSignature_zoeTitleAfterInlineImagePlaceholder_stripsPlaceholderAndSignature', () => {
    expect(removeSignature(body + 'Zoë Martin | Sales Director' + contact)).toBe('Thanks, will do.')
  })

  it('removeSignature_asciiNameTitleAfterInlineImagePlaceholder_stripsPlaceholderAndSignature', () => {
    expect(removeSignature(body + 'Nora Dupont | Sales Director' + contact)).toBe(
      'Thanks, will do.',
    )
  })
})
