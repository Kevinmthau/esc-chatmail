import { describe, expect, it } from 'vitest'
import {
  extractAllEmails,
  extractDisplayName,
  extractEmail,
  isBetterDisplayName,
  isBetterDisplayNameForEmail,
  isEmailAddressShapedDisplayName,
  isGmailAddress,
  isHideMyEmailDisplayName,
  normalizeEmail,
  stripWrappingQuotes,
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
    // Revert-check: unquoted display-name brackets must not become part of
    // the address capture, or it returns "3 Jerry <tom@x.com".
    expect(extractEmail('Tom <3 Jerry <tom@x.com>')).toBe('tom@x.com')
  })

  it.each([
    '"a<b"@example.com',
    '"a>b"@example.com',
    '"a<b>c"@example.com',
    '"a@<b>"@example.com',
    String.raw`"a\"<b"@example.com`,
    String.raw`"a\\<b"@example.com`,
    String.raw`"a\<b\>"@example.com`,
  ])('preserves angle brackets and escapes inside a quoted local part: %s', (email) => {
    expect(extractEmail(`Display <${email}>`)).toBe(email)
    expect(extractEmail(`Tom <3 Jerry <${email}>`)).toBe(email)
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

  it('returns null for a name that is only quotes', () => {
    // The emptiness check used to run before the quotes were removed, so
    // `"" <a@b>` gave an empty-string name where iOS gives none.
    // Revert-check: restoring the old `name === '' ? null : name.replaceAll(...)`
    // order in `extractDisplayName` fails this test.
    expect(extractDisplayName('"" <alice@example.com>')).toBeNull()
  })

  // Ported from EmailNormalizerTests' RFC 2047 cases (iOS issue #149).
  // Revert-check: dropping the `decodeRfc2047` call in `sanitizeDisplayName`
  // fails every case but the malformed one.
  describe('RFC 2047 encoded names', () => {
    it.each([
      ['a base64 name', '=?utf-8?B?SsO2cmcgTcO8bGxlcg==?= <jorg@example.com>', 'Jörg Müller'],
      ['a Q-encoded name', '=?utf-8?q?Jos=C3=A9_Garc=C3=ADa?= <jose@example.com>', 'José García'],
      [
        'a quoted encoded name',
        '"=?utf-8?Q?Costco_Wholesale?=" <news@costco.example.com>',
        'Costco Wholesale',
      ],
      // "=?utf-8?B?IkFjbWUsIEluYyI=?=" decodes to "\"Acme, Inc\"" — the
      // quotes only appear after decoding and must still be stripped.
      [
        'a name decoding to a quoted phrase',
        '=?utf-8?B?IkFjbWUsIEluYyI=?= <hello@acme.example.com>',
        'Acme, Inc',
      ],
      // Multibyte character split across adjacent encoded words.
      [
        'a name split across encoded words',
        '=?UTF-8?B?ww==?= =?UTF-8?B?iW1pbGll?= <emilie@example.com>',
        'Émilie',
      ],
      ['a comment name', 'jose@example.com (=?utf-8?B?Sm9zw6k=?=)', 'José'],
      [
        'a malformed word, kept verbatim',
        '=?utf-8?B?!!!notbase64!!!?= <x@example.com>',
        '=?utf-8?B?!!!notbase64!!!?=',
      ],
    ])('decodes %s', (_label, header, expected) => {
      expect(extractDisplayName(header)).toBe(expected)
    })
  })

  // Outlook and Exchange wrap a recipient's name in single quotes, bare or
  // inside the quoted string, and sanitizing kept them, so titles showed
  // `'Jacob Laycock'`. Each header form the extractor parses is covered.
  describe('Outlook quote-wrapped names', () => {
    const email = 'jacob.laycock@studs.com'

    // Revert-check: dropping the `stripWrappingQuotes` call in
    // `sanitizeDisplayName` fails this test.
    it.each([
      `'Jacob Laycock' <${email}>`,
      `"'Jacob Laycock'" <${email}>`,
      `"‘Jacob Laycock’" <${email}>`,
      `“Jacob Laycock” <${email}>`,
      `"' Jacob Laycock '" <${email}>`,
      `${email} ('Jacob Laycock')`,
      `'Jacob Laycock' ${email}`,
    ])('peels the quotes from %s', (header) => {
      expect(extractDisplayName(header)).toBe('Jacob Laycock')
    })

    // Revert-check: dropping the `stripWrappingQuotes` call in
    // `sanitizeDisplayName` fails this test.
    it("yields the bare address for Outlook's nameless recipient, and no name for only quotes", () => {
      expect(extractDisplayName(`"'${email}'" <${email}>`)).toBe(email)
      expect(extractDisplayName(`"''" <${email}>`)).toBeNull()
      expect(extractDisplayName("'Patrick O'Brien' <pobrien@example.com>")).toBe("Patrick O'Brien")
    })

    // A name that becomes quote-wrapped only once decoded is peeled too:
    // decoding runs before quote-stripping.
    // Revert-check: peeling before `decodeRfc2047` in `sanitizeDisplayName`
    // fails this test, and so does dropping its `stripWrappingQuotes` call.
    it.each([
      `=?utf-8?B?J0phY29iIExheWNvY2sn?= <${email}>`,
      `=?utf-8?Q?=27Jacob_Laycock=27?= <${email}>`,
    ])('peels quotes that appear only after decoding %s', (header) => {
      expect(extractDisplayName(header)).toBe('Jacob Laycock')
    })

    // HONEST SCOPE: passes without the peel too. It fails if the peel
    // over-matches: a quote inside a name, or one that does not wrap the
    // whole name (Google Groups' relay form), is part of the name.
    it.each([
      ["Patrick O'Brien <pobrien@example.com>", "Patrick O'Brien"],
      ["'Til Tuesday <band@example.com>", "'Til Tuesday"],
      [
        `"'Jacob Laycock' via Studs Team" <studs-team@googlegroups.com>`,
        "'Jacob Laycock' via Studs Team",
      ],
    ])('keeps a quote that does not wrap the whole name: %s', (header, expected) => {
      expect(extractDisplayName(header)).toBe(expected)
    })
  })
})

describe('stripWrappingQuotes', () => {
  it('peels every layer of every recognized pair, trimming between layers', () => {
    expect(stripWrappingQuotes("  'Jake'  ")).toBe('Jake')
    expect(stripWrappingQuotes('"‘ «Jake» ’"')).toBe('Jake')
    expect(stripWrappingQuotes('“Jake”')).toBe('Jake')
    expect(stripWrappingQuotes("''")).toBe('')
  })

  it('only trims a value whose quotes do not wrap it', () => {
    expect(stripWrappingQuotes(" O'Brien ")).toBe("O'Brien")
    expect(stripWrappingQuotes("'Til Tuesday")).toBe("'Til Tuesday")
    expect(stripWrappingQuotes("'")).toBe("'")
    // Mismatched pair: a typographic opener with an ASCII closer.
    expect(stripWrappingQuotes("‘Jake'")).toBe("‘Jake'")
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

  // The rest of this block is ported from EmailNormalizerTests'
  // `isBetterDisplayName(_:than:forEmail:)` cases.
  it('replaces a single-part address-derived name', () => {
    expect(isBetterDisplayNameForEmail('Kevin', 'Kmthau', 'kmthau@example.com')).toBe(true)
  })

  it('keeps a more complete address-derived name', () => {
    expect(isBetterDisplayNameForEmail('John', 'John Doe', 'john.doe@example.com')).toBe(false)
  })

  it('prefers intentional header casing', () => {
    expect(
      isBetterDisplayNameForEmail('BONBONWHIMS', 'Bonbonwhims', 'bonbonwhims@example.com'),
    ).toBe(true)
  })

  describe('RFC 2047 encoded-word names', () => {
    // A garbled raw encoded-word persisted by an earlier build must lose to
    // any decoded candidate — even a "shorter" single-part one.
    // Revert-check: dropping the `containsEncodedWord` guard in
    // `isBetterDisplayNameForEmail` fails this test.
    it('lets a decoded name replace persisted encoded-word garbage', () => {
      expect(isBetterDisplayNameForEmail('José', '=?utf-8?B?Sm9zw6k=?=', 'jose@example.com')).toBe(
        true,
      )
    })

    // Revert-check: dropping the `containsEncodedWord` guard in
    // `isBetterDisplayNameForEmail` fails this test.
    it('never lets an encoded word replace a clean name', () => {
      expect(isBetterDisplayNameForEmail('=?utf-8?B?Sm9zw6k=?=', 'José', 'jose@example.com')).toBe(
        false,
      )
    })
  })

  // A To/Cc header written as `"jacob.laycock@studs.com" <jacob.laycock@studs.com>`
  // splits into more comparison parts than the address-derived "Jacob
  // Laycock", which is how it used to take the stored name.
  describe('address-shaped names', () => {
    const email = 'jacob.laycock@studs.com'

    // Revert-check: dropping the `isEmailAddressShapedDisplayName` guard in
    // `isBetterDisplayNameForEmail` fails this test.
    it('never lets an address replace the address-derived name', () => {
      expect(isBetterDisplayNameForEmail(email, 'Jacob Laycock', email)).toBe(false)
    })

    // Revert-check: dropping the `isEmailAddressShapedDisplayName` guard in
    // `isBetterDisplayNameForEmail` fails this test (the longer address beat
    // a one-word name of the same part count).
    it('never lets an address replace a one-word name', () => {
      expect(isBetterDisplayNameForEmail(email, 'Jake', email)).toBe(false)
    })

    // The other half of the rule, and what heals a row that already holds
    // the address: the next header that names the person replaces it.
    // Revert-check: dropping the `isEmailAddressShapedDisplayName` guard in
    // `isBetterDisplayNameForEmail` fails this test (a one-word name shorter
    // than the address never won it back).
    it('lets a name replace an address', () => {
      expect(isBetterDisplayNameForEmail('Jake', email, email)).toBe(true)
    })

    // The stored name must not depend on which header was processed last.
    // Revert-check: dropping the `isEmailAddressShapedDisplayName` guard in
    // `isBetterDisplayNameForEmail` fails this test (From-then-Cc order ended
    // on the address).
    it('does not flip a name to the address with header order', () => {
      expect(fold(email, ['Jacob Laycock', email])).toBe('Jacob Laycock')
      expect(fold(email, [email, 'Jacob Laycock'])).toBe('Jacob Laycock')
    })

    // HONEST SCOPE: passes without the guard too. It pins what the guard
    // leaves alone: an address-shaped name still fills an empty slot, so a
    // Person named only by such a header is stored exactly as before.
    it('still lets an address fill an empty name', () => {
      expect(isBetterDisplayNameForEmail(email, null, email)).toBe(true)
    })

    // The encoded-word guard runs first: a raw encoded-word on screen is
    // worse than an address, so a decoded address-shaped candidate still
    // replaces it.
    // Revert-check: moving the `isEmailAddressShapedDisplayName` guard above
    // the `containsEncodedWord` guard in `isBetterDisplayNameForEmail` fails
    // this test.
    it('still lets an address replace encoded-word garbage', () => {
      expect(
        isBetterDisplayNameForEmail('jose@example.com', '=?utf-8?B?Sm9zw6k=?=', 'jose@example.com'),
      ).toBe(true)
    })

    // Revert-check: dropping the `normalizeEmail(candidate) === normalizeEmail(email)`
    // term in `isEmailAddressShapedDisplayName` fails this test (each address
    // outranked the one-word name by length).
    it.each([
      ['ops@intranet', 'Ops'],
      ['jose@correo.españa', 'José'],
      ['ops@[192.0.2.1]', 'Ops'],
    ])('never lets own address %s, which the bare pattern misses, replace %s', (address, name) => {
      expect(isBetterDisplayNameForEmail(address, name, address)).toBe(false)
      expect(isBetterDisplayNameForEmail(name, address, address)).toBe(true)
    })

    // A row stored before sanitizing peeled the quotes holds the quoted
    // address. The ranking peels a name before testing its shape, and the
    // shape test peels it again, so the address is caught twice.
    // Revert-check: dropping both the peel at the top of
    // `isBetterDisplayNameForEmail` (ranking the names as stored) and the
    // `stripWrappingQuotes` call in `isEmailAddressShapedDisplayName` fails
    // this test (the quoted address outranked "Jake" as the longer one-part
    // name, and the address-derived "Jacob Laycock" on comparison parts);
    // either one alone keeps it passing.
    it.each(['Jake', 'Jacob Laycock'])("never lets Outlook's 'addr' replace %s", (name) => {
      const quoted = `'${email}'`
      expect(isBetterDisplayNameForEmail(quoted, name, email)).toBe(false)
      expect(isBetterDisplayNameForEmail(name, quoted, email)).toBe(true)
    })
  })

  describe('quote-wrapped stored names', () => {
    const email = 'jacob.laycock@studs.com'

    // Person rows stored before sanitizing peeled Outlook's quotes hold
    // `'Jacob Laycock'`. The same name without its quotes replaces it, so the
    // next header that names him heals the row, and never the reverse: for
    // jacob.laycock@ the quotes hid that `'Jacob Laycock'` restates the
    // address, so it replaced the derived "Jacob Laycock" at an equal part
    // count, which could never win back.
    // Revert-check: dropping the `unquotedNew === unquotedExisting`
    // comparison in `isBetterDisplayNameForEmail` fails this test (each pair
    // tied once peeled, so the quoted row stayed), and so does ranking the
    // names as stored instead of peeled.
    it.each(["'Jacob Laycock'", '‘Jacob Laycock’', "'Jake'", "''Jake Laycock''"])(
      'lets the unquoted form replace %s, never the reverse',
      (quoted) => {
        const unquoted = stripWrappingQuotes(quoted)
        expect(isBetterDisplayNameForEmail(unquoted, quoted, email)).toBe(true)
        expect(isBetterDisplayNameForEmail(quoted, unquoted, email)).toBe(false)
      },
    )

    it('lets fewer quote layers win, and ties spellings with as many quotes', () => {
      expect(isBetterDisplayNameForEmail("'Jake'", "''Jake''", email)).toBe(true)
      // Two spellings with as many quotes tie and keep the stored one.
      expect(isBetterDisplayNameForEmail("'Jake'", '‘Jake’', email)).toBe(false)
    })

    // A quote-wrapped name ranks as the name inside its quotes against any
    // other name: `'Jacob Laycock'` is address-derived for jacob.laycock@, so
    // the real "Jake Laycock" replaces it at an equal part count, and quotes
    // do not make `'Jake'` the longer one-word name.
    // Revert-check: ranking the names as stored instead of peeled below the
    // peel in `isBetterDisplayNameForEmail` fails this test (the quoted names
    // won the base ranking as the longer strings).
    it('ranks a quote-wrapped name as the name inside its quotes', () => {
      expect(isBetterDisplayNameForEmail('Jake Laycock', "'Jacob Laycock'", email)).toBe(true)
      expect(isBetterDisplayNameForEmail("'Jacob Laycock'", 'Jake Laycock', email)).toBe(false)
      expect(isBetterDisplayNameForEmail('Jacob', "'Jake'", email)).toBe(true)
      expect(isBetterDisplayNameForEmail("'Jake'", 'Jacob', email)).toBe(false)
    })
  })

  describe('never better in both directions', () => {
    const email = 'jacob.laycock@studs.com'

    // For jacob.laycock@ the real "Jake Laycock" replaced the address-derived
    // "Jacob Laycock" (two parts each), and "Jacob Laycock" won it back as
    // the longer name.
    // Revert-check: dropping the part-count guard from the derived-candidate
    // branch (`newIsDerived && !existingIsDerived`) of
    // `isBetterDisplayNameForEmail` fails this test.
    it('never lets an address-derived name replace a real name of equal part count', () => {
      expect(isBetterDisplayNameForEmail('Jacob Laycock', 'Jake Laycock', email)).toBe(false)
    })

    // HONEST SCOPE: passes without the guard too. It pins the direction the
    // guard kept: at an equal part count the real name wins.
    it('lets a real name replace an address-derived name of equal part count', () => {
      expect(isBetterDisplayNameForEmail('Jake Laycock', 'Jacob Laycock', email)).toBe(true)
    })

    // The converse of "replaces a single-part address-derived name".
    // Revert-check: dropping the part-count guard from the derived-candidate
    // branch of `isBetterDisplayNameForEmail` fails this test ("Kmthau" won
    // back as the longer one-word name).
    it('never lets a single-part address-derived name replace a real name', () => {
      expect(isBetterDisplayNameForEmail('Kmthau', 'Kevin', 'kmthau@example.com')).toBe(false)
    })

    // HONEST SCOPE: passes without the guard too. The guard covers only the
    // tie: a derived name with more parts still replaces a shorter real name,
    // the converse of "keeps a more complete address-derived name".
    it('still lets a fuller address-derived name replace a shorter real name', () => {
      expect(isBetterDisplayNameForEmail('John Doe', 'John', 'john.doe@example.com')).toBe(true)
    })

    // Revert-check: restoring `unquotedNew !== unquotedExisting &&
    // hasIntentionalCasing(unquotedNew)` in place of the
    // `newHasIntentionalCasing !== hasIntentionalCasing(unquotedExisting)`
    // comparison in `isBetterDisplayNameForEmail` fails this test (the
    // uncased name then won the base ranking on word count, while the cased
    // one won on casing).
    it('never lets an uncased derived name replace an intentionally cased one', () => {
      expect(isBetterDisplayNameForEmail('jacob laycock', 'Jacob.Laycock', email)).toBe(false)
    })

    // Revert-check: restoring `unquotedNew !== unquotedExisting &&
    // hasIntentionalCasing(unquotedNew)` in place of the intentional-casing
    // comparison in `isBetterDisplayNameForEmail` fails this test (both
    // variants have intentional casing, so each replaced the other).
    it('never lets two intentionally cased derived variants replace each other', () => {
      expect(isBetterDisplayNameForEmail('JACOB LAYCOCK', 'Jacob Laycock', email)).toBe(false)
      expect(isBetterDisplayNameForEmail('Jacob Laycock', 'JACOB LAYCOCK', email)).toBe(false)
    })

    // Revert-check: dropping the part-count guard from the derived-candidate
    // branch of `isBetterDisplayNameForEmail` fails this test (From-then-Cc
    // order ended on "Jacob Laycock").
    it('does not flip between a real and an address-derived name with header order', () => {
      expect(fold(email, ['Jake Laycock', 'Jacob Laycock'])).toBe('Jake Laycock')
      expect(fold(email, ['Jacob Laycock', 'Jake Laycock'])).toBe('Jake Laycock')
    })

    // A pair ranked better in both directions makes the stored name follow
    // header order. Ties (false both ways) are allowed: they keep the stored
    // name. The failure message lists every offending pair.
    // Revert-check: dropping the part-count guard from the derived-candidate
    // branch of `isBetterDisplayNameForEmail` fails this test (Jacob Laycock /
    // Jake Laycock, Kevin / Kmthau, ...), and so does restoring
    // `unquotedNew !== unquotedExisting && hasIntentionalCasing(unquotedNew)`
    // in place of the intentional-casing comparison (BONBONWHIMS /
    // BonBonWhims, Jacob Laycock / JACOB LAYCOCK, ...), and so does returning
    // true from the `unquotedNew === unquotedExisting` comparison for every
    // pair equal once peeled ('Jake' / Jake, ...). The quote-wrapped entries
    // pin that ranking the peeled names keeps the property.
    it('never ranks both names of a pair better', () => {
      const namesByEmail: Array<[email: string, names: string[]]> = [
        [
          'bonbonwhims@example.com',
          ['BONBONWHIMS', 'Bonbonwhims', 'bonbonwhims', 'BonBonWhims', 'Bon Bon Whims'],
        ],
        [
          'jacob.laycock@studs.com',
          [
            'Jacob Laycock',
            'Jake Laycock',
            'Jake',
            'Jacob',
            'J. Laycock',
            'Jacob R. Laycock',
            'JACOB LAYCOCK',
            'jacob laycock',
            'Jacob.Laycock',
            'jacob.laycock',
            'jacob.laycock@studs.com',
            "'jacob.laycock@studs.com'",
            '‘jacob.laycock@studs.com’',
            '=?utf-8?B?SmFrZQ==?=',
            "'Jacob Laycock'",
            '‘Jacob Laycock’',
            "''Jacob Laycock''",
            "'Jake Laycock'",
            "'Jake'",
          ],
        ],
        [
          'john.doe@example.com',
          ['John', 'John Doe', 'Jonathan Doe', 'Johnny', 'JOHN DOE', 'john_doe', 'Dr. John Doe'],
        ],
        [
          'kmthau@example.com',
          ['Kevin', 'Kmthau', 'kmthau', 'KMTHAU', 'Kevin Thau', 'Kev', "'Kevin'", "'Kmthau'"],
        ],
        [
          'mary-jane.smith@example.com',
          ['Mary-Jane Smith', 'Mary Jane Smith', 'MJ Smith', 'Mary Smith', 'MARY-JANE SMITH'],
        ],
        // Address-shaped only through the participant's own address.
        ['ops@intranet', ['Ops', 'OPS', 'Operations Team', 'ops@intranet']],
      ]

      const betterBothWays: string[] = []
      for (const [pairEmail, names] of namesByEmail) {
        names.forEach((first, index) => {
          for (const second of names.slice(index + 1)) {
            if (
              isBetterDisplayNameForEmail(first, second, pairEmail) &&
              isBetterDisplayNameForEmail(second, first, pairEmail)
            ) {
              betterBothWays.push(`${pairEmail}: "${first}" / "${second}"`)
            }
          }
        })
      }

      expect(betterBothWays).toEqual([])
    })
  })
})

describe('isEmailAddressShapedDisplayName', () => {
  it('recognizes addresses and rejects names', () => {
    expect(isEmailAddressShapedDisplayName('jacob.laycock@studs.com')).toBe(true)
    expect(isEmailAddressShapedDisplayName('Jacob (jacob.laycock@studs.com)')).toBe(true)
    expect(isEmailAddressShapedDisplayName('Jacob Laycock')).toBe(false)
    expect(isEmailAddressShapedDisplayName('@jacob')).toBe(false)
    expect(isEmailAddressShapedDisplayName('Jacob @ Studs')).toBe(false)
  })

  // Header extraction takes any bracketed address, but the bare pattern
  // needs a dotted domain ending in an ASCII label, so these repeated
  // addresses are recognized only by matching the participant's own.
  // Revert-check: dropping the `normalizeEmail(candidate) === normalizeEmail(email)`
  // term in `isEmailAddressShapedDisplayName` fails this test.
  it("recognizes the participant's own address that the bare pattern misses", () => {
    for (const address of ['ops@intranet', 'jose@correo.españa', 'ops@[192.0.2.1]']) {
      expect(isEmailAddressShapedDisplayName(address), `precondition: ${address}`).toBe(false)
      expect(isEmailAddressShapedDisplayName(address, address), address).toBe(true)
    }
    expect(isEmailAddressShapedDisplayName('OPS@Intranet', 'ops@intranet')).toBe(true)
    expect(isEmailAddressShapedDisplayName('Ops', 'ops@intranet')).toBe(false)
    // Another dotless address is out of reach without the participant's own.
    expect(isEmailAddressShapedDisplayName('ops@intranet', 'admin@intranet')).toBe(false)
  })

  // Outlook writes a recipient that has no name as
  // `"'jacob.laycock@studs.com'" <jacob.laycock@studs.com>`. Header
  // sanitizing used to strip only the double quotes, so names stored before
  // it peeled the single quotes still hold `'jacob.laycock@studs.com'`.
  // Revert-check: dropping the `stripWrappingQuotes` call in
  // `isEmailAddressShapedDisplayName` fails this test.
  it("recognizes Outlook's single-quoted address", () => {
    expect(isEmailAddressShapedDisplayName("'jacob.laycock@studs.com'")).toBe(true)
    expect(isEmailAddressShapedDisplayName(" 'jacob.laycock@studs.com' ")).toBe(true)
    expect(isEmailAddressShapedDisplayName("'Jacob Laycock'")).toBe(false)
    expect(isEmailAddressShapedDisplayName("'Jacob @ Studs'")).toBe(false)
  })

  // The same peel covers every wrapping quote pair, and every layer of it.
  // Revert-check: narrowing `WRAPPING_QUOTE_PAIRS` to the ASCII single quote
  // fails this test, and so does peeling one layer only in
  // `stripWrappingQuotes`.
  it('recognizes a typographic or nested quoted address', () => {
    const email = 'jacob.laycock@studs.com'
    for (const quoted of [`‘${email}’`, `“${email}”`, `«${email}»`, `''${email}''`]) {
      expect(isEmailAddressShapedDisplayName(quoted), quoted).toBe(true)
      expect(isEmailAddressShapedDisplayName(quoted, email), quoted).toBe(true)
    }
    expect(isEmailAddressShapedDisplayName('‘Jacob Laycock’')).toBe(false)
  })

  // Revert-check: dropping the `stripWrappingQuotes` call in
  // `isEmailAddressShapedDisplayName` fails this test (the bare pattern
  // misses a dotless address, and the quotes broke the match with the
  // participant's own).
  it("recognizes the participant's own single-quoted dotless address", () => {
    expect(isEmailAddressShapedDisplayName("'ops@intranet'"), 'precondition').toBe(false)
    expect(isEmailAddressShapedDisplayName("'ops@intranet'", 'ops@intranet')).toBe(true)
  })
})

/** Folds header names into a stored name the way ingestion does, in order. */
function fold(email: string, candidates: string[]): string | null {
  return candidates.reduce<string | null>(
    (stored, candidate) =>
      isBetterDisplayNameForEmail(candidate, stored, email) ? candidate : stored,
    null,
  )
}

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
