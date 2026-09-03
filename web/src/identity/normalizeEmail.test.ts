import { describe, expect, it } from 'vitest'
import {
  extractAllEmails,
  extractDisplayName,
  extractEmail,
  isBetterDisplayName,
  isBetterDisplayNameForEmail,
  isGmailAddress,
  isHideMyEmailDisplayName,
  normalizeEmail,
} from './normalizeEmail'

describe('normalizeEmail', () => {
  const cases: Array<[raw: string, expected: string]> = [
    // trim + lowercase for everyone
    ['  Alice@Example.COM  ', 'alice@example.com'],
    ['alice@example.com', 'alice@example.com'],
    // gmail: dots stripped from local part
    ['j.o.h.n@gmail.com', 'john@gmail.com'],
    // gmail: '+tag' truncated
    ['john+newsletters@gmail.com', 'john@gmail.com'],
    // gmail: dots + plus + case together
    ['J.O.H.N+Tag.More@GMAIL.com', 'john@gmail.com'],
    // googlemail canonicalized to gmail.com
    ['john@googlemail.com', 'john@gmail.com'],
    ['J.ohn+x@GoogleMail.com', 'john@gmail.com'],
    // non-gmail domains: dots and plus are preserved (only trim/lowercase)
    ['j.o.h.n@example.com', 'j.o.h.n@example.com'],
    ['john+tag@example.com', 'john+tag@example.com'],
    ['First.Last+Tag@Company.ORG', 'first.last+tag@company.org'],
    // dots in the gmail DOMAIN are untouched; only the local part is stripped
    ['a.b@gmail.com.example.com', 'a.b@gmail.com.example.com'],
    // no @ at all: trim + lowercase only
    ['  NotAnEmail  ', 'notanemail'],
    // plus before dot removal interaction: dots stripped first, then truncate
    ['a.+b.c@gmail.com', 'a@gmail.com'],
  ]

  it.each(cases)('normalizeEmail(%j) -> %j', (raw, expected) => {
    expect(normalizeEmail(raw)).toBe(expected)
  })
})

describe('isGmailAddress', () => {
  it('matches gmail and googlemail domains case-insensitively', () => {
    expect(isGmailAddress('a@gmail.com')).toBe(true)
    expect(isGmailAddress('a@GoogleMail.com')).toBe(true)
    expect(isGmailAddress('a@example.com')).toBe(false)
  })
})

describe('extractEmail', () => {
  it('prefers the angle-bracket address', () => {
    expect(extractEmail('Alice Smith <alice@example.com>')).toBe('alice@example.com')
    expect(extractEmail('"Smith, Alice" <alice@example.com>')).toBe('alice@example.com')
  })

  it('ignores an unbalanced angle bracket in the display name', () => {
    // Revert-check: extractEmail must exclude both angle brackets from the
    // address capture, or it returns "3 Jerry <tom@x.com".
    expect(extractEmail('Tom <3 Jerry <tom@x.com>')).toBe('tom@x.com')
  })

  it('falls back to a bare address', () => {
    expect(extractEmail('alice@example.com')).toBe('alice@example.com')
    expect(extractEmail('Alice alice@example.com')).toBe('alice@example.com')
    expect(extractEmail('alice@example.com (Alice)')).toBe('alice@example.com')
  })

  it('returns null when nothing matches', () => {
    expect(extractEmail('not an email')).toBeNull()
    expect(extractEmail('')).toBeNull()
  })
})

describe('extractAllEmails', () => {
  it('splits comma-separated recipients', () => {
    expect(extractAllEmails('A <a@x.com>, b@y.com, "C" <c@z.org>')).toEqual([
      'a@x.com',
      'b@y.com',
      'c@z.org',
    ])
  })
})

describe('extractDisplayName', () => {
  it('handles "Name" <a@b>', () => {
    expect(extractDisplayName('"Alice Smith" <alice@example.com>')).toBe('Alice Smith')
    expect(extractDisplayName('Alice Smith <alice@example.com>')).toBe('Alice Smith')
    expect(extractDisplayName('<alice@example.com>')).toBeNull()
  })

  it('handles a@b (Name)', () => {
    expect(extractDisplayName('alice@example.com (Alice Smith)')).toBe('Alice Smith')
    expect(extractDisplayName('alice@example.com ()')).toBeNull()
  })

  it('handles Name a@b', () => {
    expect(extractDisplayName('Alice Smith alice@example.com')).toBe('Alice Smith')
    expect(extractDisplayName('alice@example.com')).toBeNull()
  })

  it('returns null with no address present', () => {
    expect(extractDisplayName('just some words')).toBeNull()
  })
})

describe('isBetterDisplayName', () => {
  it('empty/missing new name is never better', () => {
    expect(isBetterDisplayName('', 'Alice')).toBe(false)
    expect(isBetterDisplayName(null, 'Alice')).toBe(false)
  })

  it('anything beats an empty existing name', () => {
    expect(isBetterDisplayName('Alice', '')).toBe(true)
    expect(isBetterDisplayName('Alice', null)).toBe(true)
  })

  it('more parts win; equal parts fall back to length', () => {
    expect(isBetterDisplayName('Alice Smith', 'Alice')).toBe(true)
    expect(isBetterDisplayName('Alice', 'Alice Smith')).toBe(false)
    expect(isBetterDisplayName('Alexandra', 'Alice')).toBe(true)
    expect(isBetterDisplayName('Alice', 'Alice')).toBe(false)
  })
})

describe('isBetterDisplayNameForEmail', () => {
  it('replaces an address-derived name with a real one', () => {
    expect(isBetterDisplayNameForEmail('Alice Smith', 'Alice.smith', 'alice.smith@x.com')).toBe(
      true,
    )
  })

  it('keeps a real existing name against a shorter candidate', () => {
    expect(isBetterDisplayNameForEmail('Alice', 'Alice Smith', 'alice@x.com')).toBe(false)
  })

  // Parity with Swift EmailNormalizer.hasIntentionalCasing, which filters with
  // Character.isLetter: caseless-script letters (CJK etc.) COUNT as letters,
  // but are neither uppercase nor lowercase.
  describe('intentional-casing check on caseless scripts', () => {
    it('upgrades an address-derived CJK name whose recased variant adds an uppercase letter', () => {
      // Swift sees letters [汉, 字, X] (count 3) with an uppercase X after the
      // first letter -> intentional casing -> replace. A filter that only
      // keeps cased letters sees [X] alone and refuses the upgrade.
      expect(isBetterDisplayNameForEmail('汉字X', '汉字x', '汉字x@x.com')).toBe(true)
    })

    it('does not treat an all-caseless name as intentionally cased', () => {
      // 汉 and 字 satisfy `ch === ch.toUpperCase()`, so an uppercase check
      // missing the cased guard would call this ALL-CAPS and wrongly upgrade;
      // Swift's Character.isUppercase is false for both, and the candidate is
      // no better than the existing name (same parts, same length).
      expect(isBetterDisplayNameForEmail('汉_字', '汉-字', '汉.字@x.com')).toBe(false)
    })
  })
})

describe('isHideMyEmailDisplayName', () => {
  it('matches the placeholder in its variants', () => {
    expect(isHideMyEmailDisplayName('Hide My Email')).toBe(true)
    expect(isHideMyEmailDisplayName('hide-my-email')).toBe(true)
    expect(isHideMyEmailDisplayName('  hide_my_email ')).toBe(true)
    expect(isHideMyEmailDisplayName('Hide   My   Email')).toBe(true)
  })

  it('rejects real names and absent values', () => {
    expect(isHideMyEmailDisplayName('Alice')).toBe(false)
    expect(isHideMyEmailDisplayName('')).toBe(false)
    expect(isHideMyEmailDisplayName(null)).toBe(false)
    expect(isHideMyEmailDisplayName(undefined)).toBe(false)
  })
})
