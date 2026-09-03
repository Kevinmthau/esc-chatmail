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
})
