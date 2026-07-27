import { describe, expect, it } from 'vitest'
import { matchesConversationSearch } from './conversationSearch'

const row = (displayName: string, snippet: string) => ({ displayName, snippet })

describe('matchesConversationSearch (iOS ConversationFilterService.matchesSearch)', () => {
  const alice = row('Alice Chen', 'Lunch on Thursday?')

  it.each([
    ['name hit', 'Alice', true],
    ['name substring, not a prefix', 'lice', true],
    ['snippet hit', 'Thursday', true],
    ['snippet substring mid-word', 'urs', true],
    ['query lowercase vs mixed-case name', 'alice chen', true],
    ['query uppercase vs mixed-case snippet', 'LUNCH', true],
    ['no match in either field', 'Bogota', false],
  ])('%s', (_label, query, expected) => {
    expect(matchesConversationSearch(alice, query)).toBe(expected)
  })

  it('matches everything when the query is empty (search off)', () => {
    expect(matchesConversationSearch(row('', ''), '')).toBe(true)
    expect(matchesConversationSearch(alice, '')).toBe(true)
  })

  it('never reads message bodies — only the rolled-up name and snippet', () => {
    // The word lives in the thread but not in the conversation's own snippet;
    // iOS's local search cannot find it, and neither may we.
    const conversation = row('Ben Ortiz', 'Got it, will review tonight.')
    expect(matchesConversationSearch(conversation, 'quarterly')).toBe(false)
  })

  it('is case-insensitive on both sides of the comparison', () => {
    expect(matchesConversationSearch(row('ALL CAPS CO', ''), 'caps')).toBe(true)
    expect(matchesConversationSearch(row('all caps co', ''), 'CAPS')).toBe(true)
  })

  it('takes the query literally — no trimming, no tokenizing', () => {
    // Parity with iOS: `matchesSearch` is the final visibility gate there and
    // it uses the raw debounced text, so a trailing space narrows results.
    expect(matchesConversationSearch(alice, 'Alice ')).toBe(true)
    expect(matchesConversationSearch(alice, 'Chen ')).toBe(false)
    // Multi-word queries are one substring, not independent terms.
    expect(matchesConversationSearch(alice, 'Alice Thursday')).toBe(false)
  })
})
