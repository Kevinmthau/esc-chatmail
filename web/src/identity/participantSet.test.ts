import { afterEach, describe, expect, it, vi } from 'vitest'
import corpusJson from '@fixtures/golden_message_corpus.json'
import { preparePersistPlan } from '@/sync/persist'
import type { GmailHeader } from '@/gmail/types'
import { normalizeEmail } from './normalizeEmail'
import {
  calculateParticipantHash,
  compareSwiftStrings,
  makeConversationIdentity,
  makeParticipantSetIdentity,
  makeRecipientParticipantSetIdentity,
} from './participantSet'

// Cross-platform contract with iOS: these hex digests were computed with
//   printf 'p|<key>' | shasum -a 256
// and must never change — they are what keeps web and iOS conversations keyed
// identically.
const VECTORS = {
  // printf 'p|alice@example.com'
  single: '40a52bc29ccb934b1822f2249662cce17c8dce77dd4c16036141d1ee1a15a5e5',
  // printf 'p|alice@example.com|bob@example.com'
  sortedPair: 'ec4db5bd2c6b0d995f2b4987e203c26c20ca4d6fd34e88cd49214dd2d8cd3394',
  // printf 'p|me@gmail.com'
  noteToSelf: '055af9c691b347492db7cb1f4b0840ea753d1c1ab7a20a41a54b2aadfe4cb6ad',
  // printf 'p|john@gmail.com'
  gmailNormalized: 'a6549f01c8978be46c9196dc8b9bd4ddd293ceca91f2decedcf41e6128b554cd',
  // printf 'p|unknown@email.com'
  unknownFallback: '7b6bc9d36f60e002fa5780007ad24370917020b475f2f876feea9f82956d78e3',
}

describe('calculateParticipantHash parity vectors', () => {
  it('single participant', () => {
    expect(calculateParticipantHash(['alice@example.com'])).toBe(VECTORS.single)
  })

  it('multi-participant input is sorted before hashing', () => {
    expect(calculateParticipantHash(['bob@example.com', 'alice@example.com'])).toBe(
      VECTORS.sortedPair,
    )
    expect(calculateParticipantHash(['alice@example.com', 'bob@example.com'])).toBe(
      VECTORS.sortedPair,
    )
  })

  it('gmail dot/plus normalization feeds the hash', () => {
    const normalized = normalizeEmail('J.o.h.n+news@GoogleMail.com')
    expect(normalized).toBe('john@gmail.com')
    expect(calculateParticipantHash([normalized])).toBe(VECTORS.gmailNormalized)
  })
})

// Swift's `sorted()` compares canonically (NFC) normalized Unicode scalars;
// the JS default sort compares raw UTF-16 code units. These vectors pin the
// Swift ordering for the two divergent shapes (combining sequences and astral
// characters) while the joined/hashes bytes stay the ORIGINAL un-normalized
// strings, exactly as Swift joins them.
describe('participant sort matches Swift Unicode ordering', () => {
  it('combining-accent address sorts by its NFC form (e-acute > z), not by its first code unit', () => {
    // "e" + U+0301 NFC-normalizes to U+00E9 (233 > 'z' = 122), so Swift
    // orders z first; UTF-16 code units would order 'e' (101) first.
    // printf 'p|z@x.com|e\xcc\x81tudiant@x.fr' | shasum -a 256
    const decomposed = 'e\u0301tudiant@x.fr'
    expect(compareSwiftStrings(decomposed, 'z@x.com')).toBeGreaterThan(0)
    expect(makeParticipantSetIdentity(new Set([decomposed, 'z@x.com']), new Set()).participants) //
      .toEqual(['z@x.com', decomposed])
    expect(calculateParticipantHash([decomposed, 'z@x.com'])).toBe(
      '11a44aa115d87379898b788a2de450d3984f23890b615bb2f26bda3cb6f8e7eb',
    )
  })

  it('astral character sorts by code point, not by its lead surrogate', () => {
    // U+1F600 (128512) > U+FFFD (65533) in scalar order, but its lead
    // surrogate 0xD83D (55357) < 0xFFFD in UTF-16 code-unit order.
    // printf 'p|\xef\xbf\xbd@x.com|\xf0\x9f\x98\x80@x.com' | shasum -a 256
    const astral = '\u{1F600}@x.com'
    const replacement = '\uFFFD@x.com'
    expect(compareSwiftStrings(astral, replacement)).toBeGreaterThan(0)
    expect(calculateParticipantHash([astral, replacement])).toBe(
      '92cf32b37e62c8e21ba00dc50ca496eed48552ee133a832b11a5dbd9013bd01d',
    )
  })

  it('is byte-identical to the default sort for ASCII input', () => {
    const emails = ['z@x.com', 'alice@example.com', 'Bob@example.com', 'bob@example.com', 'a@x.com']
    expect([...emails].sort(compareSwiftStrings)).toEqual([...emails].sort())
  })
})

describe('makeParticipantSetIdentity', () => {
  it('removes my aliases and sorts the remainder', () => {
    const identity = makeParticipantSetIdentity(
      new Set(['bob@example.com', 'me@gmail.com', 'alice@example.com']),
      new Set(['me@gmail.com']),
    )
    expect(identity.participants).toEqual(['alice@example.com', 'bob@example.com'])
    expect(identity.participantHash).toBe(VECTORS.sortedPair)
    expect(identity.type).toBe('group')
  })

  it('single remaining participant is oneToOne', () => {
    const identity = makeParticipantSetIdentity(
      new Set(['alice@example.com', 'me@gmail.com']),
      new Set(['me@gmail.com']),
    )
    expect(identity.participants).toEqual(['alice@example.com'])
    expect(identity.participantHash).toBe(VECTORS.single)
    expect(identity.type).toBe('oneToOne')
  })

  it('note-to-self falls back to the sorted-first alias', () => {
    const identity = makeParticipantSetIdentity(
      new Set(['me@gmail.com', 'me@work.com']),
      new Set(['me@work.com', 'me@gmail.com']),
    )
    expect(identity.participants).toEqual(['me@gmail.com'])
    expect(identity.participantHash).toBe(VECTORS.noteToSelf)
    expect(identity.type).toBe('oneToOne')
  })

  it('empty remainder with no aliases falls back to sorted-first email', () => {
    const identity = makeParticipantSetIdentity(new Set(['me@gmail.com']), new Set())
    expect(identity.participants).toEqual(['me@gmail.com'])
    expect(identity.participantHash).toBe(VECTORS.noteToSelf)
  })

  it('nothing at all falls back to unknown@email.com', () => {
    const identity = makeParticipantSetIdentity(new Set(), new Set())
    expect(identity.participants).toEqual(['unknown@email.com'])
    expect(identity.participantHash).toBe(VECTORS.unknownFallback)
    expect(identity.type).toBe('oneToOne')
  })
})

describe('makeRecipientParticipantSetIdentity', () => {
  it('normalizes raw recipients before keying', () => {
    const identity = makeRecipientParticipantSetIdentity(['  J.o.h.n+x@GoogleMail.com '], new Set())
    expect(identity?.participants).toEqual(['john@gmail.com'])
    expect(identity?.participantHash).toBe(VECTORS.gmailNormalized)
  })

  it('returns null when nothing normalizes to a usable address', () => {
    expect(makeRecipientParticipantSetIdentity([], new Set())).toBeNull()
    expect(makeRecipientParticipantSetIdentity(['   '], new Set())).toBeNull()
  })
})

describe('makeConversationIdentity', () => {
  it('keeps the participantHash but mints a unique keyHash per epoch', () => {
    const setIdentity = makeParticipantSetIdentity(new Set(['alice@example.com']), new Set())
    const a = makeConversationIdentity(setIdentity)
    const b = makeConversationIdentity(setIdentity)

    expect(a.participantHash).toBe(VECTORS.single)
    expect(b.participantHash).toBe(VECTORS.single)
    expect(a.keyHash).not.toBe(b.keyHash)
    expect(a.key.startsWith('p|alice@example.com|')).toBe(true)
    expect(a.participants).toEqual(['alice@example.com'])
    expect(a.type).toBe('oneToOne')
  })

  it('carries display names through', () => {
    const setIdentity = makeParticipantSetIdentity(new Set(['alice@example.com']), new Set())
    const identity = makeConversationIdentity(setIdentity, { 'alice@example.com': 'Alice' })
    expect(identity.participantDisplayNames).toEqual({ 'alice@example.com': 'Alice' })
  })

  // crypto.randomUUID is [SecureContext]: it is undefined on a plain-http LAN
  // origin (http://192.168.x.x:5173 from a phone), where it used to throw
  // "crypto.randomUUID is not a function" on the first conversation created.
  describe('in an insecure context (no crypto.randomUUID)', () => {
    afterEach(() => {
      vi.unstubAllGlobals()
    })

    function stubInsecureContext(): void {
      const real = globalThis.crypto
      vi.stubGlobal('crypto', {
        getRandomValues: <T extends ArrayBufferView>(array: T): T => real.getRandomValues(array),
      })
    }

    it('still mints unique epochs and leaves the parity hash untouched', () => {
      stubInsecureContext()
      const setIdentity = makeParticipantSetIdentity(new Set(['alice@example.com']), new Set())
      const a = makeConversationIdentity(setIdentity)
      const b = makeConversationIdentity(setIdentity)

      expect(a.key.startsWith('p|alice@example.com|')).toBe(true)
      expect(a.keyHash).not.toBe(b.keyHash)
      // The cross-platform contract must not shift with the id source.
      expect(a.participantHash).toBe(VECTORS.single)
      expect(b.participantHash).toBe(VECTORS.single)
    })
  })
})

interface ConversationIdentityCase {
  id: string
  headers: GmailHeader[]
  myAliases: string[]
  expected: {
    participants: string[]
    participantHash: string
    type: 'oneToOne' | 'group'
    listId: null
  }
  notes?: string
}

const corpus = corpusJson as unknown as {
  conversationIdentityCases: ConversationIdentityCase[]
}

// Replay through the production header-to-identity path, so parser, alias,
// BCC and Hide My Email behavior are pinned alongside the hash bytes.
// Revert-check: weakening extractEmail's angle-bracket bounds breaks the
// unbalanced-display-name case; dropping identityParticipants' HME filter
// breaks the To/Cc relay cases.
describe('golden corpus: conversationIdentityCases', () => {
  it('has cases', () => {
    expect(corpus.conversationIdentityCases.length).toBeGreaterThan(0)
  })

  it.each(corpus.conversationIdentityCases.map((c) => [c.id, c] as const))(
    '%s',
    async (_id, scenario) => {
      const plan = await preparePersistPlan(
        {
          id: scenario.id,
          threadId: `thread-${scenario.id}`,
          payload: {
            mimeType: 'text/plain',
            headers: scenario.headers,
          },
        },
        {
          myAliases: new Set(scenario.myAliases.map(normalizeEmail)),
          sendAsAliases: [],
          knownLabelIds: null,
        },
      )
      expect(plan.kind, scenario.notes).toBe('message')
      if (plan.kind !== 'message') return

      expect(plan.identity.participants, scenario.notes).toEqual(scenario.expected.participants)
      expect(plan.identity.participantHash, scenario.notes).toBe(scenario.expected.participantHash)
      expect(plan.identity.type, scenario.notes).toBe(scenario.expected.type)
      // Web has no list-conversation model; this shared section only covers
      // participant identities. Do not silently treat list vectors as parity.
      expect(scenario.expected.listId).toBeNull()
    },
  )
})
