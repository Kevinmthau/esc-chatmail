import { describe, expect, it } from 'vitest'
import { addressTokens } from './address'

describe('addressTokens', () => {
  it.each(['Tom <3 Jerry <tom@x.com>', 'Tom <<3 Jerry <tom@x.com>'])(
    'preserves the next recipient after an unbalanced display-name bracket in %s',
    (first) => {
      expect(addressTokens(`${first}, Alice <alice@example.com>`)).toEqual([
        first,
        'Alice <alice@example.com>',
      ])
    },
  )

  it.each([
    { name: 'quoted display-name delimiters', first: '"Smith, Alice <Team>" <alice@example.com>' },
    { name: 'quoted local-part delimiters', first: '<"a<,b>"@example.com>' },
    { name: 'escaped quotes', first: String.raw`"Alice \"<lead>, Team\"" <alice@example.com>` },
    { name: 'escaped backslashes', first: String.raw`"Alice \\" <alice@example.com>` },
  ])('preserves $name while splitting the next recipient', ({ first }) => {
    expect(addressTokens(`${first}, bob@example.com`)).toEqual([first, 'bob@example.com'])
  })

  it('trims tokens and ignores empty recipients', () => {
    expect(addressTokens(' , alice@example.com, , bob@example.com, ')).toEqual([
      'alice@example.com',
      'bob@example.com',
    ])
  })

  // Revert-check: dropping the 'comment' (or, for the angle-addr row, the
  // 'angleComment') mode from `addressTokens` splits each of these at the
  // comma inside the comment.
  it.each([
    ['a comma inside a comment', '(<boss@corp.example>, x) <x@attacker.example>'],
    ['a nested comment', '(a (b, c) d) <x@attacker.example>'],
    ['an escaped paren inside a comment', String.raw`(a \), b) <x@attacker.example>`],
    ['a comma inside an angle-addr comment', '<me@gmail.com (>, <boss@corp.example>)>'],
  ])('keeps %s inside its mailbox', (_name, first) => {
    expect(addressTokens(`${first}, bob@example.com`)).toEqual([first, 'bob@example.com'])
  })

  it('runs a comment that never closes to the end, as a quote that never closes does', () => {
    expect(addressTokens('(a, <b@example.com>, c@example.com')).toEqual([
      '(a, <b@example.com>, c@example.com',
    ])
  })

  it('treats a quote inside a comment as text', () => {
    expect(addressTokens('(") <a@example.com>, <b@example.com>')).toEqual([
      '(") <a@example.com>',
      '<b@example.com>',
    ])
  })
})
