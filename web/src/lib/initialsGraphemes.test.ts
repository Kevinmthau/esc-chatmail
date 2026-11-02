import { describe, expect, it } from 'vitest'
import { initials } from './initials'

// InitialsAvatarView takes `prefix(n)` over Swift Characters (grapheme
// clusters). Slicing UTF-16 code units cut an astral first character in half
// and the Avatar drew the lone surrogate as U+FFFD.
//
// Revert-check: initials' graphemePrefix. Back on `slice(0, n)`, the
// emoji-leading cases return a lone high surrogate ('\uD83D' + 'B').

describe('initials over grapheme clusters', () => {
  it('an emoji-leading first word keeps the emoji whole', () => {
    expect(initials('\u{1F600} Bob')).toBe('\u{1F600}B')
  })

  it('an emoji-leading second word keeps the emoji whole', () => {
    expect(initials('Bob \u{1F600}')).toBe('B\u{1F600}')
  })

  it('a ZWJ emoji sequence counts as one character, as a Swift Character does', () => {
    expect(initials('\u{1F469}‍\u{1F4BB} Dev')).toBe('\u{1F469}‍\u{1F4BB}D')
  })

  it('a single word with prefix length 2 takes two characters, not two code units', () => {
    expect(initials('\u{1F600}Bob', 2)).toBe('\u{1F600}B')
    expect(initials('\u{1F600}\u{1F601}x', 2)).toBe('\u{1F600}\u{1F601}')
    expect(initials('\u{1F600}Bob', 1)).toBe('\u{1F600}')
  })

  it('a flag (two regional indicators) is one character', () => {
    expect(initials('\u{1F1EB}\u{1F1F7} Paris')).toBe('\u{1F1EB}\u{1F1F7}P')
  })

  it('a combining accent stays attached to its base letter', () => {
    expect(initials('élise', 1)).toBe('É')
  })

  it('ASCII names are unchanged', () => {
    expect(initials('Kevin Thau')).toBe('KT')
    expect(initials('kevin', 2)).toBe('KE')
    expect(initials('   ')).toBe('?')
  })
})
