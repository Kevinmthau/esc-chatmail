import { describe, expect, it } from 'vitest'
import { initials } from './initials'

describe('initials', () => {
  it('uses first letters of the first two words', () => {
    expect(initials('Kevin Thau')).toBe('KT')
    expect(initials('Ada Lovelace King')).toBe('AL')
  })

  it('uses the prefix length for single words', () => {
    expect(initials('kevin', 2)).toBe('KE')
    expect(initials('kevin', 1)).toBe('K')
  })

  it('falls back to ? for empty names', () => {
    expect(initials('')).toBe('?')
    expect(initials('   ')).toBe('?')
  })
})
