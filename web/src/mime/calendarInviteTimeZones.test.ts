// Non-IANA TZID resolution: Exchange/Outlook invites name Windows zones and
// ship the offsets in a VTIMEZONE; the parser must land on the sender's
// instant instead of reading the wall clock in the viewer's zone.
//
// Every expectation is an absolute UTC instant, so the suite holds in any
// runner zone; the floating fallback the fix replaces only coincides with it
// when the runner happens to sit in the invite's own zone.

import { describe, expect, it } from 'vitest'
import { ianaAliasForTimeZone, parseICalendarEvent } from './calendarInvite'

/** VTIMEZONE exactly as Exchange writes it for Eastern (US). */
const EASTERN_VTIMEZONE = [
  'BEGIN:VTIMEZONE',
  'TZID:Eastern Standard Time',
  'BEGIN:STANDARD',
  'DTSTART:16010101T020000',
  'TZOFFSETFROM:-0400',
  'TZOFFSETTO:-0500',
  'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11',
  'END:STANDARD',
  'BEGIN:DAYLIGHT',
  'DTSTART:16010101T020000',
  'TZOFFSETFROM:-0500',
  'TZOFFSETTO:-0400',
  'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3',
  'END:DAYLIGHT',
  'END:VTIMEZONE',
]

/** VTIMEZONE as Exchange writes it for W. Europe (Berlin). */
const W_EUROPE_VTIMEZONE = [
  'BEGIN:VTIMEZONE',
  'TZID:W. Europe Standard Time',
  'BEGIN:STANDARD',
  'DTSTART:16010101T030000',
  'TZOFFSETFROM:+0200',
  'TZOFFSETTO:+0100',
  'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10',
  'END:STANDARD',
  'BEGIN:DAYLIGHT',
  'DTSTART:16010101T020000',
  'TZOFFSETFROM:+0100',
  'TZOFFSETTO:+0200',
  'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3',
  'END:DAYLIGHT',
  'END:VTIMEZONE',
]

function outlookInvite(timeZoneLines: readonly string[], tzid: string, start: string, end: string) {
  return [
    'BEGIN:VCALENDAR',
    'METHOD:REQUEST',
    'PRODID:Microsoft Exchange Server 2010',
    'VERSION:2.0',
    ...timeZoneLines,
    'BEGIN:VEVENT',
    'ORGANIZER;CN=Pat Organizer:mailto:pat@example.com',
    'SUMMARY:Quarterly review',
    `DTSTART;TZID=${tzid}:${start}`,
    `DTEND;TZID=${tzid}:${end}`,
    'UID:040000008200E00074C5B7101A82E008',
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n')
}

describe('VTIMEZONE resolution', () => {
  // Revert-check: collectTimeZoneComponents / epochMsFromTimeZoneComponent —
  // without the VTIMEZONE pass and with the alias table removed, the wall
  // clock is read as floating and the instant moves with the runner's zone.
  it('resolves an Eastern Standard Time invite in July through its DAYLIGHT observance', () => {
    const event = parseICalendarEvent(
      outlookInvite(
        EASTERN_VTIMEZONE,
        'Eastern Standard Time',
        '20260715T100000',
        '20260715T103000',
      ),
    )

    // 10:00 EDT (UTC-4) → 14:00Z.
    expect(event?.startMs).toBe(Date.UTC(2026, 6, 15, 14, 0, 0))
    expect(event?.endMs).toBe(Date.UTC(2026, 6, 15, 14, 30, 0))
    expect(event?.timeZone).toBe('America/New_York')
  })

  it('resolves an Eastern Standard Time invite in January through its STANDARD observance', () => {
    const event = parseICalendarEvent(
      outlookInvite(
        EASTERN_VTIMEZONE,
        'Eastern Standard Time',
        '20260120T100000',
        '20260120T110000',
      ),
    )

    // 10:00 EST (UTC-5) → 15:00Z; the prior November transition is the one in effect.
    expect(event?.startMs).toBe(Date.UTC(2026, 0, 20, 15, 0, 0))
    expect(event?.endMs).toBe(Date.UTC(2026, 0, 20, 16, 0, 0))
  })

  it('resolves a W. Europe Standard Time invite on both sides of the last-Sunday rules', () => {
    const summer = parseICalendarEvent(
      outlookInvite(
        W_EUROPE_VTIMEZONE,
        'W. Europe Standard Time',
        '20260715T100000',
        '20260715T110000',
      ),
    )
    // 10:00 CEST (UTC+2) → 08:00Z.
    expect(summer?.startMs).toBe(Date.UTC(2026, 6, 15, 8, 0, 0))
    expect(summer?.timeZone).toBe('Europe/Berlin')

    const winter = parseICalendarEvent(
      outlookInvite(
        W_EUROPE_VTIMEZONE,
        'W. Europe Standard Time',
        '20261110T100000',
        '20261110T110000',
      ),
    )
    // 10:00 CET (UTC+1) → 09:00Z: the 25 October 2026 (last Sunday) switch has happened.
    expect(winter?.startMs).toBe(Date.UTC(2026, 10, 10, 9, 0, 0))
  })

  it('lands on the correct side of the transition day itself', () => {
    // DST ends 1 Nov 2026 (first Sunday) at 02:00 EDT. 00:30 is EDT, 03:00 is EST.
    const before = parseICalendarEvent(
      outlookInvite(
        EASTERN_VTIMEZONE,
        'Eastern Standard Time',
        '20261101T003000',
        '20261101T010000',
      ),
    )
    expect(before?.startMs).toBe(Date.UTC(2026, 10, 1, 4, 30, 0))

    const after = parseICalendarEvent(
      outlookInvite(
        EASTERN_VTIMEZONE,
        'Eastern Standard Time',
        '20261101T030000',
        '20261101T033000',
      ),
    )
    expect(after?.startMs).toBe(Date.UTC(2026, 10, 1, 8, 0, 0))
  })

  // Revert-check: epochMsFromTimeZoneComponent's `Math.min(...holding)` — the
  // fall-back hour exists twice; reading it in the later observance (EST) lands
  // an hour after the IANA path reads the same wall clock in America/New_York.
  it('reads the repeated fall-back hour as its first occurrence, like the IANA path', () => {
    const viaDocument = parseICalendarEvent(
      outlookInvite(
        EASTERN_VTIMEZONE,
        'Eastern Standard Time',
        '20261101T010000',
        '20261101T013000',
      ),
    )
    const viaIana = parseICalendarEvent(
      outlookInvite([], 'America/New_York', '20261101T010000', '20261101T013000'),
    )

    // 01:00 EDT (the first 01:00 that night) → 05:00Z.
    expect(viaDocument?.startMs).toBe(Date.UTC(2026, 10, 1, 5, 0, 0))
    expect(viaIana?.startMs).toBe(Date.UTC(2026, 10, 1, 5, 0, 0))
  })

  // Revert-check: epochMsFromTimeZoneComponent's `Math.max(...instants)`
  // branch — the spring-forward hour has no holding reading.
  it('carries a wall clock inside the spring-forward gap forward by the gap', () => {
    // DST begins 8 Mar 2026 (second Sunday) at 02:00 EST → 03:00 EDT; 02:30 never happens.
    const event = parseICalendarEvent(
      outlookInvite(
        EASTERN_VTIMEZONE,
        'Eastern Standard Time',
        '20260308T023000',
        '20260308T030000',
      ),
    )
    // Read as 03:30 EDT → 07:30Z.
    expect(event?.startMs).toBe(Date.UTC(2026, 2, 8, 7, 30, 0))
  })

  // Revert-check: epochMsFromTimeZoneComponent — a zone with no alias and no
  // Intl support is only resolvable through the document.
  it('resolves a TZID known only to the document, keeping its own name as the zone label', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VTIMEZONE',
        'TZID:Customer Time',
        'BEGIN:STANDARD',
        'DTSTART:19700101T000000',
        'TZOFFSETFROM:+0530',
        'TZOFFSETTO:+0530',
        'END:STANDARD',
        'END:VTIMEZONE',
        'BEGIN:VEVENT',
        'DTSTART;TZID=Customer Time:20260715T100000',
        'SUMMARY:Fixed-offset zone',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )

    // 10:00 at +05:30 → 04:30Z.
    expect(event?.startMs).toBe(Date.UTC(2026, 6, 15, 4, 30, 0))
    expect(event?.timeZone).toBe('Customer Time')
  })

  it('reads the VTIMEZONE even when it follows the VEVENT', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART;TZID=Eastern Standard Time:20260715T100000',
        'SUMMARY:Zone declared later',
        'END:VEVENT',
        ...EASTERN_VTIMEZONE,
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.startMs).toBe(Date.UTC(2026, 6, 15, 14, 0, 0))
  })

  it('does not let a VTIMEZONE observance SUMMARY-less DTSTART leak into the event', () => {
    // The VTIMEZONE's own DTSTART lines sit inside STANDARD/DAYLIGHT; the
    // event's start must come from the VEVENT alone.
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        ...EASTERN_VTIMEZONE,
        'BEGIN:VEVENT',
        'SUMMARY:No start',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event).toBeNull()
  })
})

describe('Windows time-zone aliases', () => {
  // Revert-check: WINDOWS_TIME_ZONE_ALIASES / ianaAliasForTimeZone — a
  // Windows-named TZID without a VTIMEZONE (a forwarded or stripped invite)
  // falls to floating without the table.
  it('resolves a Windows TZID without a VTIMEZONE through the alias table', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART;TZID=Pacific Standard Time:20260715T100000',
        'DTEND;TZID=Pacific Standard Time:20260715T110000',
        'SUMMARY:No VTIMEZONE shipped',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )

    // 10:00 PDT (UTC-7) → 17:00Z.
    expect(event?.startMs).toBe(Date.UTC(2026, 6, 15, 17, 0, 0))
    expect(event?.endMs).toBe(Date.UTC(2026, 6, 15, 18, 0, 0))
    expect(event?.timeZone).toBe('America/Los_Angeles')
  })

  it('maps the common Exchange zone names case-insensitively', () => {
    expect(ianaAliasForTimeZone('Eastern Standard Time')).toBe('America/New_York')
    expect(ianaAliasForTimeZone('w. europe standard time')).toBe('Europe/Berlin')
    expect(ianaAliasForTimeZone('AUS Eastern Standard Time')).toBe('Australia/Sydney')
    expect(ianaAliasForTimeZone('Tokyo Standard Time')).toBe('Asia/Tokyo')
    expect(ianaAliasForTimeZone('GMT Standard Time')).toBe('Europe/London')
    expect(ianaAliasForTimeZone('India Standard Time')).toBe('Asia/Kolkata')
    expect(ianaAliasForTimeZone('Not A Zone')).toBeNull()
  })

  it('keeps an IANA TZID on the direct path, ahead of any alias', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART;TZID=America/New_York:20260715T100000',
        'SUMMARY:IANA',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.startMs).toBe(Date.UTC(2026, 6, 15, 14, 0, 0))
    expect(event?.timeZone).toBe('America/New_York')
  })

  it('still reads a TZID nothing can resolve as floating local time', () => {
    const event = parseICalendarEvent(
      [
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'DTSTART;TZID=Nowhere Time:20260715T100000',
        'SUMMARY:Unknown zone',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\r\n'),
    )
    expect(event?.startMs).toBe(new Date(2026, 6, 15, 10, 0, 0).getTime())
    expect(event?.timeZone).toBe('')
  })
})
