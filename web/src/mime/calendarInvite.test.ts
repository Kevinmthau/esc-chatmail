// Calendar-invite detection (port of CalendarInviteSignals +
// Message.computeIsLikelyCalendarInvite) and iCalendar extraction.

import { describe, expect, it } from 'vitest'
import type { GmailMessage, GmailPart } from '../gmail/types'
import {
  analyzeCalendarInvite,
  isLikelyCalendarInvite,
  parseICalendarEvent,
} from './calendarInvite'
import { parseGmailMessage } from './parse'

function b64url(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let binary = ''
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function message(payload: GmailPart, overrides: Partial<GmailMessage> = {}): GmailMessage {
  return {
    id: 'msg-1',
    threadId: 'thread-1',
    internalDate: '1753000000000',
    labelIds: ['INBOX'],
    payload,
    ...overrides,
  }
}

function headers(subject: string, from = 'Alice Smith <alice@example.com>') {
  return [
    { name: 'Subject', value: subject },
    { name: 'From', value: from },
    { name: 'To', value: 'me@example.com' },
  ]
}

// --- Fixtures ----------------------------------------------------------------

const REQUEST_ICS = [
  'BEGIN:VCALENDAR',
  'PRODID:-//Google Inc//Google Calendar 70.9054//EN',
  'VERSION:2.0',
  'CALSCALE:GREGORIAN',
  'METHOD:REQUEST',
  'BEGIN:VEVENT',
  'DTSTART;TZID=America/New_York:20260318T140000',
  'DTEND;TZID=America/New_York:20260318T150000',
  'DTSTAMP:20260310T120000Z',
  'ORGANIZER;CN=Alice Smith:mailto:alice@example.com',
  'UID:abc123@google.com',
  'SUMMARY:Design sync',
  'LOCATION:Conference Room B\\, 4th floor',
  'STATUS:CONFIRMED',
  'END:VEVENT',
  'END:VCALENDAR',
].join('\r\n')

const CANCEL_ICS = [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'METHOD:CANCEL',
  'BEGIN:VEVENT',
  'DTSTART:20260318T180000Z',
  'DTEND:20260318T190000Z',
  'ORGANIZER;CN=Alice Smith:mailto:alice@example.com',
  'SUMMARY:Design sync',
  'STATUS:CANCELLED',
  'END:VEVENT',
  'END:VCALENDAR',
].join('\r\n')

/** A real Google invite: alternative bodies plus the inline text/calendar. */
function inviteMessage(ics: string, subject: string, method = 'REQUEST'): GmailMessage {
  return message(
    {
      partId: '',
      mimeType: 'multipart/mixed',
      headers: headers(subject),
      parts: [
        {
          partId: '0',
          mimeType: 'multipart/alternative',
          parts: [
            {
              partId: '0.0',
              mimeType: 'text/plain',
              body: {
                data: b64url(
                  'You have been invited to the following event.\n\nDesign sync\n\nWhen\nWed Mar 18, 2026 2:00pm – 3:00pm (EDT)\nWhere\nConference Room B\nGuests\nalice@example.com - organizer\n',
                ),
              },
            },
            {
              partId: '0.1',
              mimeType: 'text/html',
              body: { data: b64url('<html><body><p>Design sync</p></body></html>') },
            },
            {
              partId: '0.2',
              mimeType: `text/calendar; charset="UTF-8"; method=${method}`,
              body: { data: b64url(ics) },
            },
          ],
        },
        {
          partId: '1',
          mimeType: 'application/ics',
          filename: 'invite.ics',
          body: { attachmentId: 'att-1', size: ics.length },
        },
      ],
    },
    { snippet: 'You have been invited to the following event.' },
  )
}

// --- Detection ---------------------------------------------------------------

describe('calendar invite detection', () => {
  it('detects a real text/calendar invite', async () => {
    const parsed = await parseGmailMessage(inviteMessage(REQUEST_ICS, 'Invitation: Design sync'))
    expect(parsed?.isLikelyCalendarInvite).toBe(true)
  })

  it('detects a Google Calendar HTML invite with no iCalendar part', async () => {
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'text/html',
        headers: headers('Invitation: Quarterly review @ Fri Apr 3, 2026 9am'),
        body: {
          data: b64url(
            '<html><body><p>Invitation from Google Calendar</p>' +
              '<p>Quarterly review</p><p>Fri Apr 3, 2026 9:00am</p></body></html>',
          ),
        },
      }),
    )
    expect(parsed?.isLikelyCalendarInvite).toBe(true)
    // No iCalendar part to extract from — the message still degrades cleanly.
    expect(parsed?.calendarEvent).toBeNull()
  })

  it('detects a cancellation', async () => {
    const parsed = await parseGmailMessage(
      inviteMessage(CANCEL_ICS, 'Canceled: Design sync', 'CANCEL'),
    )
    expect(parsed?.isLikelyCalendarInvite).toBe(true)
    expect(parsed?.calendarEvent?.method).toBe('CANCEL')
    expect(parsed?.calendarEvent?.status).toBe('CANCELLED')
  })

  it('does not flag a newsletter that merely mentions a date', async () => {
    const parsed = await parseGmailMessage(
      message(
        {
          partId: '',
          mimeType: 'text/plain',
          headers: headers('This week at the co-op', 'News <news@coop.example.com>'),
          body: {
            data: b64url(
              'Our spring market opens Sat Mar 21, 2026 10:00am.\nCome early for the pastries.\n',
            ),
          },
        },
        { snippet: 'Our spring market opens Sat Mar 21, 2026 10:00am.' },
      ),
    )
    expect(parsed?.isLikelyCalendarInvite).toBe(false)
    expect(parsed?.calendarEvent).toBeNull()
  })

  it('keeps the flag but yields no event for a malformed VEVENT, without throwing', async () => {
    const malformed = [
      'BEGIN:VCALENDAR',
      'METHOD:REQUEST',
      'BEGIN:VEVENT',
      'SUMMARY:Broken invite',
      'DTSTART;TZID=America/New_York:not-a-timestamp',
      'DTEND',
      'END:VCALENDAR',
    ].join('\r\n')

    const parsed = await parseGmailMessage(inviteMessage(malformed, 'Invitation: Broken invite'))
    expect(parsed?.isLikelyCalendarInvite).toBe(true)
    expect(parsed?.calendarEvent).toBeNull()
  })

  it('needs more than a text/calendar part alone', () => {
    // hasCalendarPart is only decisive alongside a prefix/structure/date signal
    // (Message.computeIsLikelyCalendarInvite).
    expect(
      isLikelyCalendarInvite({
        subject: 'Notes from today',
        snippet: 'Attaching my notes.',
        bodyText: 'Attaching my notes.',
        hasCalendarPart: true,
      }),
    ).toBe(false)
    expect(
      isLikelyCalendarInvite({
        subject: 'Invitation: Design sync',
        snippet: '',
        bodyText: '',
        hasCalendarPart: true,
      }),
    ).toBe(true)
  })

  it('accepts the structural When/Where text block without a calendar part', () => {
    expect(
      isLikelyCalendarInvite({
        subject: 'Invitation: Design sync',
        snippet: null,
        bodyText: 'Design sync\nWhen\nWed Mar 18, 2026 2:00pm\nWhere\nRoom B\n',
        hasCalendarPart: false,
      }),
    ).toBe(true)
  })

  it('survives a payload with no parts at all', () => {
    expect(
      analyzeCalendarInvite({
        payload: undefined,
        subject: null,
        snippet: null,
        bodyText: null,
      }),
    ).toEqual({ isLikelyCalendarInvite: false, event: null })
  })
})

// --- Extraction --------------------------------------------------------------

describe('iCalendar extraction', () => {
  it('extracts title, times, location, and organizer across a TZID', () => {
    const event = parseICalendarEvent(REQUEST_ICS)
    expect(event).not.toBeNull()
    expect(event?.title).toBe('Design sync')
    // 2026-03-18 14:00 America/New_York is EDT (UTC-4) → 18:00Z.
    expect(event?.startMs).toBe(Date.UTC(2026, 2, 18, 18, 0, 0))
    expect(event?.endMs).toBe(Date.UTC(2026, 2, 18, 19, 0, 0))
    expect(event?.timeZone).toBe('America/New_York')
    expect(event?.isAllDay).toBe(0)
    expect(event?.location).toBe('Conference Room B, 4th floor')
    expect(event?.organizer).toBe('Alice Smith')
    expect(event?.method).toBe('REQUEST')
  })

  it('resolves a standard-time TZID on the other side of the DST boundary', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART;TZID=America/New_York:20260118T140000',
        'SUMMARY:Winter sync',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    // January is EST (UTC-5) → 19:00Z, not 18:00Z.
    expect(event?.startMs).toBe(Date.UTC(2026, 0, 18, 19, 0, 0))
  })

  it('anchors an all-day event to UTC midnight', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'METHOD:REQUEST',
        'BEGIN:VEVENT',
        'DTSTART;VALUE=DATE:20260704',
        'DTEND;VALUE=DATE:20260706',
        'SUMMARY:Team offsite',
        'LOCATION:Portland',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.isAllDay).toBe(1)
    expect(event?.startMs).toBe(Date.UTC(2026, 6, 4))
    expect(event?.endMs).toBe(Date.UTC(2026, 6, 6))
    expect(event?.timeZone).toBe('')
  })

  it('unfolds folded lines and unescapes text values', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART:20260318T180000Z',
        'SUMMARY:Quarterly planning with the whole',
        '  extended team',
        'LOCATION:Building 4\\; Room 12\\, west wing',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.title).toBe('Quarterly planning with the whole extended team')
    expect(event?.location).toBe('Building 4; Room 12, west wing')
  })

  it('normalizes a Meet link location and falls back to the mailto organizer', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART:20260318T180000Z',
        'SUMMARY:Remote standup',
        'LOCATION:https://meet.google.com/abc-defg-hij',
        'ORGANIZER:mailto:alice@example.com',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.location).toBe('Google Meet')
    expect(event?.organizer).toBe('alice@example.com')
  })

  it('ignores an end that is not after the start', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART:20260318T180000Z',
        'DTEND:20260318T180000Z',
        'SUMMARY:Zero length',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.endMs).toBe(0)
  })

  it('reads only the first VEVENT of a recurring series', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART:20260318T180000Z',
        'SUMMARY:Weekly sync',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'RECURRENCE-ID:20260325T180000Z',
        'DTSTART:20260325T190000Z',
        'SUMMARY:Weekly sync (moved)',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.title).toBe('Weekly sync')
    expect(event?.startMs).toBe(Date.UTC(2026, 2, 18, 18, 0, 0))
  })

  it('returns null when there is no start instant', () => {
    expect(
      parseICalendarEvent(
        ['BEGIN:VCALENDAR', 'BEGIN:VEVENT', 'SUMMARY:No date', 'END:VEVENT', 'END:VCALENDAR'].join(
          '\r\n',
        ),
      ),
    ).toBeNull()
    expect(parseICalendarEvent('')).toBeNull()
    expect(parseICalendarEvent('not an ics document at all')).toBeNull()
  })

  it('falls back to the invite subject when SUMMARY is missing', () => {
    const analysis = analyzeCalendarInvite({
      payload: {
        mimeType: 'text/calendar; method=REQUEST',
        body: {
          data: b64url(
            [
              'BEGIN:VCALENDAR',
              'BEGIN:VEVENT',
              'DTSTART:20260318T180000Z',
              'END:VEVENT',
              'END:VCALENDAR',
            ].join('\r\n'),
          ),
        },
      },
      subject: 'Invitation: Design sync @ Wed Mar 18, 2026 2pm - 3pm (EDT)',
      snippet: null,
      bodyText: null,
    })
    expect(analysis.event?.title).toBe('Design sync')
    expect(analysis.event?.method).toBe('REQUEST')
  })
})
