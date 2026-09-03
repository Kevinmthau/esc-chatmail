import { describe, expect, it } from 'vitest'
import type { MsgParticipantRow } from '@/db/types'
import { strictParticipantSetIdentity } from './strictIdentity'

function row(email: string, kind: MsgParticipantRow['kind'], displayName = ''): MsgParticipantRow {
  return { messageId: 'm1', email, displayName, kind }
}

const MY_ALIASES = new Set(['me@gmail.com'])
/** No people rows: the HME check falls back to the frozen row display name. */
const NO_PEOPLE = new Map<string, string>()

describe('strictParticipantSetIdentity', () => {
  it('returns null when no participant rows exist (optimistic sends are never re-homed)', () => {
    expect(strictParticipantSetIdentity([], 'alice@example.com', MY_ALIASES, NO_PEOPLE)).toBeNull()
  })

  it('derives the set from from+to+cc rows', () => {
    const identity = strictParticipantSetIdentity(
      [
        row('alice@example.com', 'from', 'Alice'),
        row('me@gmail.com', 'to'),
        row('bob@example.com', 'cc'),
      ],
      '',
      MY_ALIASES,
      NO_PEOPLE,
    )
    expect(identity?.participants).toEqual(['alice@example.com', 'bob@example.com'])
    expect(identity?.type).toBe('group')
  })

  it('excludes bcc rows from identity', () => {
    const identity = strictParticipantSetIdentity(
      [row('alice@example.com', 'from'), row('secret@example.com', 'bcc')],
      '',
      MY_ALIASES,
      NO_PEOPLE,
    )
    expect(identity?.participants).toEqual(['alice@example.com'])
  })

  it('bcc-only rows count as no identity rows at all', () => {
    expect(
      strictParticipantSetIdentity([row('secret@example.com', 'bcc')], '', MY_ALIASES, NO_PEOPLE),
    ).toBeNull()
  })

  it('senderEmail supplements a legacy row set missing a from row', () => {
    const identity = strictParticipantSetIdentity(
      [row('me@gmail.com', 'to')],
      'A.l.i.c.e+x@GoogleMail.com',
      MY_ALIASES,
      NO_PEOPLE,
    )
    expect(identity?.participants).toEqual(['alice@gmail.com'])
  })

  it('senderEmail is ignored when a from row exists', () => {
    const identity = strictParticipantSetIdentity(
      [row('alice@example.com', 'from')],
      'other@example.com',
      MY_ALIASES,
      NO_PEOPLE,
    )
    expect(identity?.participants).toEqual(['alice@example.com'])
  })

  it('drops a Hide-My-Email from row but still counts it as a from row', () => {
    const identity = strictParticipantSetIdentity(
      [row('relay@privaterelay.appleid.com', 'from', 'Hide My Email'), row('me@gmail.com', 'to')],
      'relay@privaterelay.appleid.com',
      MY_ALIASES,
      NO_PEOPLE,
    )
    // The relay address is excluded and senderEmail must NOT re-add it, so this
    // resolves to the note-to-self fallback.
    expect(identity?.participants).toEqual(['me@gmail.com'])
  })

  it.each(['to', 'cc'] as const)('drops a legacy Hide-My-Email %s row', (kind) => {
    // Revert-check: strictParticipantSetIdentity must check HME names outside
    // the from-only branch, including its fallback when no Person is present.
    const identity = strictParticipantSetIdentity(
      [row('alice@example.com', 'from'), row('relay@icloud.com', kind, 'Hide My Email')],
      '',
      MY_ALIASES,
      NO_PEOPLE,
    )
    expect(identity?.participants).toEqual(['alice@example.com'])
    expect(identity?.type).toBe('oneToOne')
  })

  it('returns null when every usable email drops out', () => {
    expect(
      strictParticipantSetIdentity(
        [row('relay@privaterelay.appleid.com', 'from', 'hide-my-email')],
        '',
        MY_ALIASES,
        NO_PEOPLE,
      ),
    ).toBeNull()
  })

  it('self-only rows fall back to note-to-self', () => {
    const identity = strictParticipantSetIdentity(
      [row('me@gmail.com', 'from'), row('me@gmail.com', 'to')],
      '',
      MY_ALIASES,
      NO_PEOPLE,
    )
    expect(identity?.participants).toEqual(['me@gmail.com'])
    expect(identity?.type).toBe('oneToOne')
  })

  // iOS tests `participant.person?.displayName` — the LIVE, enrichable Person
  // record — for the Hide-My-Email placeholder, not the header name frozen on
  // the participant row. The people map stands in for db.people.
  describe('Hide-My-Email check reads the enriched person name', () => {
    it.each(['to', 'cc'] as const)('drops a %s row enriched to Hide My Email', (kind) => {
      // Revert-check: the current Person name must be checked for every
      // non-BCC kind, even when the frozen row name is empty.
      const identity = strictParticipantSetIdentity(
        [row('alice@example.com', 'from'), row('relay@icloud.com', kind)],
        '',
        MY_ALIASES,
        new Map([['relay@icloud.com', 'Hide My Email']]),
      )
      expect(identity?.participants).toEqual(['alice@example.com'])
    })

    it('drops a from row whose person was enriched to Hide My Email after persist', () => {
      // Row written with an empty header name; a later message enriched the
      // person to the placeholder. iOS drops the relay; checking only the
      // frozen row name would keep it and fork the hash across platforms.
      const identity = strictParticipantSetIdentity(
        [row('relay@privaterelay.appleid.com', 'from'), row('me@gmail.com', 'to')],
        '',
        MY_ALIASES,
        new Map([['relay@privaterelay.appleid.com', 'Hide My Email']]),
      )
      expect(identity?.participants).toEqual(['me@gmail.com'])
    })

    it('keeps a from row whose frozen HME name was enriched to a real person name', () => {
      const identity = strictParticipantSetIdentity(
        [row('relay@privaterelay.appleid.com', 'from', 'Hide My Email')],
        '',
        MY_ALIASES,
        new Map([['relay@privaterelay.appleid.com', 'Janet Marie Appleseed']]),
      )
      expect(identity?.participants).toEqual(['relay@privaterelay.appleid.com'])
    })

    it('looks the person up by normalized email', () => {
      // Legacy rows can carry un-normalized emails; the person table is keyed
      // by the normalized form.
      const identity = strictParticipantSetIdentity(
        [row(' Relay@PrivateRelay.appleid.com ', 'from'), row('me@gmail.com', 'to')],
        '',
        MY_ALIASES,
        new Map([['relay@privaterelay.appleid.com', 'hide-my-email']]),
      )
      expect(identity?.participants).toEqual(['me@gmail.com'])
    })
  })
})
