import { describe, expect, it } from 'vitest'
import type { SendAsAlias } from '@/db/types'
import {
  SendAsAliasUnavailableError,
  emailAddressesInHeader,
  matchesGmailEquivalent,
  resolveReplyFrom,
  selectReplyFromAlias,
  type ReplyFromHeaders,
} from './replyFrom'

function alias(overrides: Partial<SendAsAlias>): SendAsAlias {
  return {
    email: 'user@example.com',
    displayName: '',
    isDefault: false,
    isPrimary: false,
    verificationStatus: 'accepted',
    ...overrides,
  }
}

const primary = alias({ email: 'me@example.com', isDefault: true, isPrimary: true })
const work = alias({ email: 'work@example.com' })
const school = alias({ email: 'school@example.com' })
const aliases = [primary, work, school]

function headers(overrides: Partial<ReplyFromHeaders>): ReplyFromHeaders {
  return { isSent: false, ...overrides }
}

describe('emailAddressesInHeader', () => {
  it('parses display-name, quoted, and bare address lists in order', () => {
    expect(
      emailAddressesInHeader('"Doe, Jane" <Jane@Example.com>, bob@example.com, Al <al@x.com>'),
    ).toEqual(['jane@example.com', 'bob@example.com', 'al@x.com'])
  })

  it('skips tokens without an address', () => {
    expect(emailAddressesInHeader('undisclosed-recipients:;')).toEqual([])
  })
})

describe('resolveReplyFrom ladder', () => {
  it('step 1: SENT message From alias wins over recipient aliases', () => {
    const result = resolveReplyFrom(
      headers({
        isSent: true,
        from: 'Me <work@example.com>',
        to: ['school@example.com'],
      }),
      aliases,
    )
    expect(result).toEqual({
      deliveredToAddress: 'work@example.com',
      replyFromAddress: 'work@example.com',
    })
  })

  it('step 1 does not apply to non-sent messages', () => {
    const result = resolveReplyFrom(
      headers({ from: 'work@example.com', to: ['school@example.com'] }),
      aliases,
    )
    expect(result).toEqual({
      deliveredToAddress: 'school@example.com',
      replyFromAddress: 'school@example.com',
    })
  })

  it('sent message whose From is not ours falls through the ladder', () => {
    const result = resolveReplyFrom(
      headers({ isSent: true, from: 'other@else.com', to: ['work@example.com'] }),
      aliases,
    )
    expect(result).toEqual({
      deliveredToAddress: 'work@example.com',
      replyFromAddress: 'work@example.com',
    })
  })

  it('step 2: first non-default alias among To/Cc wins', () => {
    const result = resolveReplyFrom(
      headers({ to: ['someone@else.com', 'Work <WORK@example.com>'], cc: ['school@example.com'] }),
      aliases,
    )
    expect(result).toEqual({
      deliveredToAddress: 'work@example.com',
      replyFromAddress: 'work@example.com',
    })
  })

  it('step 2 outranks forwarding headers', () => {
    const result = resolveReplyFrom(
      headers({ to: ['work@example.com'], xOriginalTo: ['school@example.com'] }),
      aliases,
    )
    expect(result.replyFromAddress).toBe('work@example.com')
  })

  it('step 3: forwarding headers outrank a default alias in To', () => {
    const result = resolveReplyFrom(
      headers({ to: ['me@example.com'], deliveredTo: ['school@example.com'] }),
      aliases,
    )
    expect(result).toEqual({
      deliveredToAddress: 'school@example.com',
      replyFromAddress: 'school@example.com',
    })
  })

  it('step 3 checks X-Original-To before Envelope-To before Delivered-To', () => {
    const result = resolveReplyFrom(
      headers({
        xOriginalTo: ['work@example.com'],
        envelopeTo: ['school@example.com'],
        deliveredTo: ['me@example.com'],
      }),
      aliases,
    )
    expect(result.replyFromAddress).toBe('work@example.com')

    const envelopeWins = resolveReplyFrom(
      headers({
        xOriginalTo: ['unknown@relay.com'],
        envelopeTo: ['school@example.com'],
      }),
      aliases,
    )
    expect(envelopeWins.replyFromAddress).toBe('school@example.com')
  })

  it('step 4: the default alias in To matches when no forwarding header does', () => {
    const result = resolveReplyFrom(headers({ to: ['me@example.com'] }), aliases)
    expect(result).toEqual({
      deliveredToAddress: 'me@example.com',
      replyFromAddress: 'me@example.com',
    })
  })

  it('step 5: unrecognized forwarding candidate keeps delivered-to, reply-from defaults', () => {
    const result = resolveReplyFrom(
      headers({ to: ['someone@else.com'], deliveredTo: ['fwd-target@relay.com'] }),
      aliases,
    )
    expect(result).toEqual({
      deliveredToAddress: 'fwd-target@relay.com',
      replyFromAddress: 'me@example.com',
    })
  })

  it('step 5 uses the FIRST forwarding candidate in header-priority order', () => {
    const result = resolveReplyFrom(
      headers({
        deliveredTo: ['later@relay.com'],
        xOriginalTo: ['first@relay.com'],
      }),
      aliases,
    )
    expect(result.deliveredToAddress).toBe('first@relay.com')
  })

  it('step 6: nothing matches, both fall back to the default alias', () => {
    const result = resolveReplyFrom(headers({ to: ['someone@else.com'] }), aliases)
    expect(result).toEqual({
      deliveredToAddress: 'me@example.com',
      replyFromAddress: 'me@example.com',
    })
  })

  it('step 6 with no aliases resolves to nulls', () => {
    expect(resolveReplyFrom(headers({ to: ['someone@else.com'] }), [])).toEqual({
      deliveredToAddress: null,
      replyFromAddress: null,
    })
  })

  it('non-sendable aliases are invisible to the resolver', () => {
    const pending = alias({ email: 'pending@example.com', verificationStatus: 'pending' })
    const result = resolveReplyFrom(headers({ to: ['pending@example.com'] }), [primary, pending])
    expect(result).toEqual({
      deliveredToAddress: 'me@example.com',
      replyFromAddress: 'me@example.com',
    })
  })
})

describe('selectReplyFromAlias', () => {
  it('returns the alias matching replyFromAddress', () => {
    expect(selectReplyFromAlias('work@example.com', 'work@example.com', aliases)).toBe(work)
  })

  it('falls back to the default alias when replyFromAddress matches nothing', () => {
    expect(selectReplyFromAlias(null, 'me@example.com', aliases)).toBe(primary)
    expect(selectReplyFromAlias(null, null, aliases)).toBe(primary)
  })

  it('throws SendAsAliasUnavailableError for an unconfigured delivered-to address', () => {
    expect(() => selectReplyFromAlias(null, 'Removed@Example.com', aliases)).toThrowError(
      SendAsAliasUnavailableError,
    )
    try {
      selectReplyFromAlias(null, 'Removed@Example.com', aliases)
      expect.unreachable()
    } catch (error) {
      expect((error as SendAsAliasUnavailableError).address).toBe('removed@example.com')
    }
  })

  it('gmail plus-tag delivered-to escapes the guard and falls back to the canonical alias', () => {
    const gmailPrimary = alias({ email: 'user@gmail.com', isDefault: true, isPrimary: true })
    const selected = selectReplyFromAlias('user+list@gmail.com', 'user+list@gmail.com', [
      gmailPrimary,
    ])
    expect(selected).toBe(gmailPrimary)
  })

  it('gmail dot-variant delivered-to escapes the guard', () => {
    const gmailPrimary = alias({ email: 'user@gmail.com', isDefault: true, isPrimary: true })
    expect(selectReplyFromAlias(null, 'u.ser@gmail.com', [gmailPrimary])).toBe(gmailPrimary)
  })

  it('the gmail equivalence escape requires both sides to be gmail', () => {
    expect(() => selectReplyFromAlias(null, 'me+tag@example.com', aliases)).toThrowError(
      SendAsAliasUnavailableError,
    )
  })

  it('a delivered-to matching the fallback email does not throw', () => {
    const selected = selectReplyFromAlias(null, 'fallback@example.com', aliases, {
      fallbackEmail: 'fallback@example.com',
    })
    expect(selected).toBe(primary)
  })

  it('with no aliases, synthesizes a fallback alias from the account email', () => {
    expect(
      selectReplyFromAlias(null, null, [], {
        fallbackEmail: ' Me@Example.com ',
        fallbackDisplayName: 'Me',
      }),
    ).toEqual({
      email: 'me@example.com',
      displayName: 'Me',
      isDefault: true,
      isPrimary: true,
      verificationStatus: 'accepted',
    })
  })

  it('with no aliases and no fallback email, throws', () => {
    expect(() => selectReplyFromAlias(null, null, [])).toThrowError(
      'No send-as alias available and no fallback account email',
    )
  })
})

describe('matchesGmailEquivalent', () => {
  it('matches dot/plus variants of the same gmail account', () => {
    expect(matchesGmailEquivalent('u.ser+x@gmail.com', 'user@googlemail.com')).toBe(true)
  })

  it('rejects non-gmail domains and different accounts', () => {
    expect(matchesGmailEquivalent('user+x@example.com', 'user@example.com')).toBe(false)
    expect(matchesGmailEquivalent('alice@gmail.com', 'bob@gmail.com')).toBe(false)
  })
})
