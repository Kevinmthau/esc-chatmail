import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ChatmailDB } from '@/db/schema'
import type { SendAsAlias } from '@/db/types'
import type { SendAsEntry } from '@/gmail/types'
import {
  buildIdentityAliasSet,
  deduplicated,
  defaultAlias,
  fromGmailSendAs,
  isAcceptedForSending,
  normalizedAliasAddress,
  persistAccountAliases,
  validAliases,
} from './aliases'

function alias(overrides: Partial<SendAsAlias>): SendAsAlias {
  return {
    email: 'user@example.com',
    displayName: '',
    isDefault: false,
    isPrimary: false,
    verificationStatus: '',
    ...overrides,
  }
}

describe('normalizedAliasAddress', () => {
  it('extracts, trims, and lowercases without Gmail canonicalization', () => {
    expect(normalizedAliasAddress('  User@Example.COM ')).toBe('user@example.com')
    expect(normalizedAliasAddress('"Jane" <Jane.Doe+tag@GMAIL.com>')).toBe('jane.doe+tag@gmail.com')
    // Dots and plus tags must survive: alias identity is exact-address.
    expect(normalizedAliasAddress('u.ser+x@gmail.com')).toBe('u.ser+x@gmail.com')
  })
})

describe('isAcceptedForSending', () => {
  it('primary is always accepted regardless of status', () => {
    expect(isAcceptedForSending(alias({ isPrimary: true, verificationStatus: 'pending' }))).toBe(
      true,
    )
  })

  it('accepted verification status is accepted, case-insensitively', () => {
    expect(isAcceptedForSending(alias({ verificationStatus: 'accepted' }))).toBe(true)
    expect(isAcceptedForSending(alias({ verificationStatus: 'ACCEPTED' }))).toBe(true)
    expect(isAcceptedForSending(alias({ verificationStatus: 'pending' }))).toBe(false)
  })

  it('a missing status falls back to isDefault', () => {
    expect(isAcceptedForSending(alias({ isDefault: true }))).toBe(true)
    expect(isAcceptedForSending(alias({}))).toBe(false)
  })

  it('a non-accepted status rejects even the default alias', () => {
    expect(isAcceptedForSending(alias({ isDefault: true, verificationStatus: 'pending' }))).toBe(
      false,
    )
  })
})

describe('fromGmailSendAs', () => {
  it('normalizes and maps an accepted entry', () => {
    const entry: SendAsEntry = {
      sendAsEmail: '  Work@Example.COM ',
      displayName: '  Work Me  ',
      isDefault: false,
      isPrimary: false,
      verificationStatus: 'accepted',
    }
    expect(fromGmailSendAs(entry)).toEqual({
      email: 'work@example.com',
      displayName: 'Work Me',
      isDefault: false,
      isPrimary: false,
      verificationStatus: 'accepted',
    })
  })

  it('rejects unaccepted and empty entries', () => {
    expect(fromGmailSendAs({ sendAsEmail: 'a@b.com', verificationStatus: 'pending' })).toBeNull()
    expect(fromGmailSendAs({ sendAsEmail: '   ' })).toBeNull()
  })
})

describe('deduplicated', () => {
  it('drops non-sendable aliases', () => {
    expect(
      deduplicated([alias({ verificationStatus: 'pending' }), alias({ isPrimary: true })]),
    ).toEqual([alias({ isPrimary: true })])
  })

  it('prefers default over primary over has-display-name; keeps first-seen order', () => {
    const primary = alias({ email: 'a@x.com', isPrimary: true })
    const dflt = alias({ email: 'A@x.com', isDefault: true, verificationStatus: 'accepted' })
    expect(deduplicated([primary, dflt])).toEqual([dflt])
    expect(deduplicated([dflt, primary])).toEqual([dflt])

    const named = alias({ email: 'a@x.com', verificationStatus: 'accepted', displayName: 'Me' })
    const unnamed = alias({ email: 'a@x.com', verificationStatus: 'accepted' })
    expect(deduplicated([unnamed, named])).toEqual([named])
    expect(deduplicated([named, unnamed])).toEqual([named])

    // Equal preference: the first entry wins.
    const first = alias({ email: 'a@x.com', verificationStatus: 'accepted', displayName: 'One' })
    const second = alias({ email: 'a@x.com', verificationStatus: 'accepted', displayName: 'Two' })
    expect(deduplicated([first, second])).toEqual([first])

    const other = alias({ email: 'b@x.com', isPrimary: true })
    expect(deduplicated([unnamed, other, named]).map((a) => a.email)).toEqual([
      'a@x.com',
      'b@x.com',
    ])
  })
})

describe('validAliases', () => {
  const sendAs: SendAsEntry[] = [
    {
      sendAsEmail: 'me@example.com',
      displayName: 'Me',
      isDefault: true,
      isPrimary: true,
    },
    { sendAsEmail: 'work@example.com', verificationStatus: 'accepted' },
    { sendAsEmail: 'unverified@example.com', verificationStatus: 'pending' },
  ]

  it('filters to accepted aliases and keeps order', () => {
    expect(validAliases(sendAs, 'me@example.com').map((a) => a.email)).toEqual([
      'me@example.com',
      'work@example.com',
    ])
  })

  it('always includes the account email, inserted first as primary', () => {
    const result = validAliases(
      [{ sendAsEmail: 'work@example.com', verificationStatus: 'accepted' }],
      'Me@Example.com',
    )
    expect(result.map((a) => a.email)).toEqual(['me@example.com', 'work@example.com'])
    expect(result[0]).toEqual({
      email: 'me@example.com',
      displayName: '',
      isDefault: true,
      isPrimary: true,
      verificationStatus: 'accepted',
    })
  })

  it('the injected account email is not default when another default exists', () => {
    const result = validAliases(
      [{ sendAsEmail: 'work@example.com', isDefault: true, verificationStatus: 'accepted' }],
      'me@example.com',
    )
    expect(result[0]).toMatchObject({ email: 'me@example.com', isDefault: false, isPrimary: true })
  })

  it('does not duplicate the account email when already present', () => {
    expect(validAliases(sendAs, 'me@example.com')).toHaveLength(2)
    expect(validAliases(sendAs)).toHaveLength(2)
  })
})

describe('defaultAlias', () => {
  it('prefers default, then primary, then first', () => {
    const d = alias({ email: 'd@x.com', isDefault: true, verificationStatus: 'accepted' })
    const p = alias({ email: 'p@x.com', isPrimary: true })
    const a = alias({ email: 'a@x.com', verificationStatus: 'accepted' })
    expect(defaultAlias([a, p, d])).toBe(d)
    expect(defaultAlias([a, p])).toBe(p)
    expect(defaultAlias([a])).toBe(a)
    expect(defaultAlias([])).toBeNull()
  })
})

describe('buildIdentityAliasSet', () => {
  it('fully normalizes (Gmail dots/plus) and always includes the account email', () => {
    const set = buildIdentityAliasSet('Me.Self+work@gmail.com', [
      { sendAsEmail: 'me.self@googlemail.com', isPrimary: true },
      { sendAsEmail: 'Other@Example.com', verificationStatus: 'accepted' },
      { sendAsEmail: 'skipped@example.com', verificationStatus: 'pending' },
    ])
    expect(set).toEqual(new Set(['meself@gmail.com', 'other@example.com']))
  })
})

describe('persistAccountAliases', () => {
  let db: ChatmailDB

  beforeEach(() => {
    db = new ChatmailDB(`test-${crypto.randomUUID()}`)
  })

  afterEach(async () => {
    await db.delete()
  })

  const sendAs: SendAsEntry[] = [
    { sendAsEmail: 'me@example.com', isDefault: true, isPrimary: true },
    { sendAsEmail: 'work@example.com', verificationStatus: 'accepted' },
  ]

  it('creates the account row when missing', async () => {
    const result = await persistAccountAliases(db, 'me@example.com', sendAs, 1234)

    const row = await db.accounts.get('me@example.com')
    expect(row).toEqual({
      email: 'me@example.com',
      historyId: '',
      aliases: ['me@example.com', 'work@example.com'],
      sendAsAliases: [
        {
          email: 'me@example.com',
          displayName: '',
          isDefault: true,
          isPrimary: true,
          verificationStatus: '',
        },
        {
          email: 'work@example.com',
          displayName: '',
          isDefault: false,
          isPrimary: false,
          verificationStatus: 'accepted',
        },
      ],
      installTs: 1234,
      sendAsRefreshedAt: 1234,
    })
    expect(result.aliases).toEqual(row?.aliases)
    expect(result.sendAsAliases).toEqual(row?.sendAsAliases)
  })

  it('updates aliases while preserving historyId and installTs', async () => {
    await db.accounts.add({
      email: 'me@example.com',
      historyId: '42',
      aliases: ['stale@example.com'],
      sendAsAliases: [],
      installTs: 1,
      sendAsRefreshedAt: 1,
    })

    await persistAccountAliases(db, 'me@example.com', sendAs, 9999)

    const row = await db.accounts.get('me@example.com')
    expect(row?.historyId).toBe('42')
    expect(row?.installTs).toBe(1)
    expect(row?.sendAsRefreshedAt).toBe(9999)
    expect(row?.aliases).toEqual(['me@example.com', 'work@example.com'])
    expect(row?.sendAsAliases.map((a) => a.email)).toEqual(['me@example.com', 'work@example.com'])
  })
})
