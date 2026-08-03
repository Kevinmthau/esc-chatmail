// Calendar-event presentation. Every assertion pins an explicit display zone
// (or an all-day event, which is always formatted in UTC) so the suite does not
// depend on the machine's TZ.

import { describe, expect, it } from 'vitest'
import type { CalendarEventData } from '@/db/types'
import { calendarStatusLabel, formatCalendarEvent } from './formatCalendarEvent'

function event(overrides: Partial<CalendarEventData> = {}): CalendarEventData {
  return {
    title: 'Design sync',
    startMs: Date.UTC(2026, 2, 18, 18, 0, 0),
    endMs: Date.UTC(2026, 2, 18, 19, 0, 0),
    timeZone: 'America/New_York',
    isAllDay: 0,
    location: 'Conference Room B',
    organizer: 'Alice Smith',
    method: 'REQUEST',
    status: 'CONFIRMED',
    source: 'Google Calendar',
    ...overrides,
  }
}

describe('formatCalendarEvent', () => {
  it('renders the date rail and a timed range in the display zone', () => {
    const display = formatCalendarEvent(event(), 'America/New_York')
    expect(display.monthSymbol).toBe('MAR')
    expect(display.dayNumber).toBe('18')
    expect(display.weekdaySymbol).toBe('WED')
    expect(display.dateTimeLine).toContain('Mar 18, 2026')
    expect(display.dateTimeLine).toContain('2:00')
    expect(display.dateTimeLine).toContain('3:00')
    // The rail already carries the date, so the clock row is times only.
    expect(display.timeLine).toContain('2:00')
    expect(display.timeLine).not.toContain('Mar')
  })

  it('leaves the zone unnamed when the invite was written in the reader s zone', () => {
    const display = formatCalendarEvent(event(), 'America/New_York')
    expect(display.timeLine).not.toContain('EDT')
  })

  it('re-anchors the same instant when the reader is in another zone, and names it', () => {
    // 18:00Z is the 19th in Tokyo — the rail must follow the reader, not the
    // organizer's zone, and the converted time is tagged so it can be trusted.
    const display = formatCalendarEvent(event(), 'Asia/Tokyo')
    expect(display.dayNumber).toBe('19')
    expect(display.weekdaySymbol).toBe('THU')
    expect(display.dateTimeLine).toContain('Mar 19, 2026')
    expect(display.dateTimeLine).toContain('3:00')
    expect(display.timeLine).toContain('GMT+9')
  })

  it('spells out the end date for an event that runs past midnight', () => {
    // 14:00 → 01:00 the next day in New York.
    const display = formatCalendarEvent(
      event({ endMs: Date.UTC(2026, 2, 19, 5, 0, 0) }),
      'America/New_York',
    )
    expect(display.dayNumber).toBe('18')
    expect(display.timeLine).toContain('Mar 19')
  })

  it('formats an all-day event in UTC so the date never slides', () => {
    const display = formatCalendarEvent(
      event({ isAllDay: 1, startMs: Date.UTC(2026, 6, 4), endMs: 0, timeZone: '' }),
    )
    expect(display.monthSymbol).toBe('JUL')
    expect(display.dayNumber).toBe('4')
    expect(display.dateTimeLine).toContain('Jul 4, 2026')
    expect(display.dateTimeLine).toContain('All day')
    expect(display.dateTimeLine).not.toContain('–')
  })

  it('shows an inclusive range for a multi-day all-day event', () => {
    const display = formatCalendarEvent(
      event({ isAllDay: 1, startMs: Date.UTC(2026, 6, 4), endMs: Date.UTC(2026, 6, 6) }),
    )
    // DTEND is exclusive: the 4th and 5th, not through the 6th.
    expect(display.dateTimeLine).toContain('Jul 4, 2026')
    expect(display.dateTimeLine).toContain('Jul 5, 2026')
    expect(display.dateTimeLine).not.toContain('Jul 6')
  })

  it('shows a single time when the event has no end', () => {
    const display = formatCalendarEvent(event({ endMs: 0 }), 'America/New_York')
    expect(display.dateTimeLine).toContain('2:00')
    expect(display.dateTimeLine).not.toContain('3:00')
  })

  it('falls back to the local zone when the override is not a real zone', () => {
    expect(() => formatCalendarEvent(event(), 'Mars/Olympus_Mons')).not.toThrow()
  })
})

describe('calendarStatusLabel', () => {
  it('prefers the iCalendar method and status over the subject', () => {
    expect(calendarStatusLabel(event({ method: 'CANCEL' }), 'Invitation: Design sync')).toBe(
      'Cancelled',
    )
    expect(calendarStatusLabel(event({ method: '', status: 'CANCELLED' }), 'Design sync')).toBe(
      'Cancelled',
    )
  })

  it('reads the subject prefixes when the method is absent', () => {
    expect(calendarStatusLabel(event({ method: '' }), 'Canceled: Design sync')).toBe('Cancelled')
    expect(calendarStatusLabel(event({ method: '' }), 'Updated invitation: Design sync')).toBe(
      'Updated',
    )
    expect(calendarStatusLabel(event({ method: '' }), 'Invitation: Design sync')).toBe('Invitation')
  })

  it('labels a REQUEST as an invitation and stays silent otherwise', () => {
    expect(calendarStatusLabel(event(), 'Design sync')).toBe('Invitation')
    expect(calendarStatusLabel(event({ method: 'PUBLISH', status: '' }), 'Design sync')).toBe('')
  })
})
