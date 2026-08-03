// Presentation of an extracted calendar event (mime/calendarInvite →
// CalendarEventData). The iOS card echoes the "When" line straight out of the
// email body, which is already localized by Google; here the event is an
// absolute instant, so the line is built with Intl in the reader's own locale —
// same convention as lib/formatTimestamp, minus its pinned 'en-US' (that one
// mirrors iOS TimestampFormatter's fixed patterns; there is no fixed pattern to
// mirror here).

import type { CalendarEventData } from '@/db/types'
import { isSupportedTimeZone } from '@/mime/calendarInvite'

export interface CalendarEventDisplay {
  /** Date-rail month, e.g. "MAR". */
  monthSymbol: string
  /** Date-rail day of month. */
  dayNumber: string
  /** Date-rail weekday, e.g. "WED". */
  weekdaySymbol: string
  /**
   * The card's clock row. Time-only when the rail already answers "which day"
   * — repeating the date there costs the one line the fixed-height card has for
   * it, and truncates the part the reader actually needs.
   */
  timeLine: string
  /** Date and time together: the accessible summary of the whole event. */
  dateTimeLine: string
}

/**
 * The zone the event should be *read* in. All-day events were anchored to UTC
 * midnight at parse time and must be formatted back in UTC or they slide a day;
 * timed events are shown in the reader's own zone.
 */
function displayTimeZone(event: CalendarEventData): string | undefined {
  if (event.isAllDay === 1) return 'UTC'
  return undefined
}

/**
 * The zone name is printed only when the invite was written in a *different*
 * zone than the reader's — that is when a converted time could be doubted.
 * Tagging "3:00 PM PDT" for a reader already in PDT is noise, and on a card
 * this narrow it is noise that truncates the times themselves.
 */
function shouldNameZone(event: CalendarEventData, displayZone: string | undefined): boolean {
  if (event.isAllDay === 1 || event.timeZone.length === 0) return false
  const readerZone = displayZone ?? new Intl.DateTimeFormat().resolvedOptions().timeZone
  return event.timeZone !== readerZone
}

function dateTimeFormat(
  options: Intl.DateTimeFormatOptions,
  timeZone: string | undefined,
): Intl.DateTimeFormat {
  if (timeZone !== undefined && isSupportedTimeZone(timeZone)) {
    return new Intl.DateTimeFormat(undefined, { ...options, timeZone })
  }
  return new Intl.DateTimeFormat(undefined, options)
}

/** Uppercased short symbol for the date rail (locale's own abbreviation). */
function railSymbol(
  date: Date,
  options: Intl.DateTimeFormatOptions,
  timeZone: string | undefined,
): string {
  return dateTimeFormat(options, timeZone).format(date).toUpperCase()
}

function formatDatePart(date: Date, timeZone: string | undefined): string {
  return dateTimeFormat(
    { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' },
    timeZone,
  ).format(date)
}

function formatTimeRange(
  startMs: number,
  endMs: number,
  timeZone: string | undefined,
  nameZone: boolean,
): string {
  const options: Intl.DateTimeFormatOptions = {
    hour: 'numeric',
    minute: '2-digit',
    ...(nameZone ? { timeZoneName: 'short' as const } : {}),
  }
  const formatter = dateTimeFormat(options, timeZone)
  if (endMs > startMs) {
    return formatter.formatRange(new Date(startMs), new Date(endMs))
  }
  return formatter.format(new Date(startMs))
}

const DAY_MS = 24 * 60 * 60 * 1000

/** Whether both instants land on the same calendar day in the display zone. */
function isSameDay(startMs: number, endMs: number, timeZone: string | undefined): boolean {
  const formatter = dateTimeFormat({ year: 'numeric', month: 'numeric', day: 'numeric' }, timeZone)
  return formatter.format(new Date(startMs)) === formatter.format(new Date(endMs))
}

/**
 * Rail symbols, the clock-row line, and the full summary. `overrideTimeZone`
 * exists for tests and never for production code — real callers pass the event
 * alone and get the reader's own zone.
 */
export function formatCalendarEvent(
  event: CalendarEventData,
  overrideTimeZone?: string,
): CalendarEventDisplay {
  const timeZone = overrideTimeZone ?? displayTimeZone(event)
  const start = new Date(event.startMs)

  const display: CalendarEventDisplay = {
    monthSymbol: railSymbol(start, { month: 'short' }, timeZone),
    dayNumber: dateTimeFormat({ day: 'numeric' }, timeZone).format(start),
    weekdaySymbol: railSymbol(start, { weekday: 'short' }, timeZone),
    timeLine: '',
    dateTimeLine: '',
  }

  const startLine = formatDatePart(start, timeZone)

  if (event.isAllDay === 1) {
    // An all-day DTEND is exclusive: 4th→6th means the 4th and the 5th.
    const lastDayMs = event.endMs > event.startMs ? event.endMs - DAY_MS : event.startMs
    if (lastDayMs > event.startMs) {
      const lastLine = formatDatePart(new Date(lastDayMs), timeZone)
      display.timeLine = `All day through ${lastLine}`
      display.dateTimeLine = `${startLine} – ${lastLine} · All day`
    } else {
      display.timeLine = 'All day'
      display.dateTimeLine = `${startLine} · All day`
    }
    return display
  }

  const timeRange = formatTimeRange(
    event.startMs,
    event.endMs,
    timeZone,
    shouldNameZone(event, timeZone),
  )
  // An event that runs past midnight needs its end date spelled out; one that
  // does not is fully described by the rail plus the times.
  display.timeLine =
    event.endMs > event.startMs && !isSameDay(event.startMs, event.endMs, timeZone)
      ? `${timeRange} (until ${formatDatePart(new Date(event.endMs), timeZone)})`
      : timeRange
  display.dateTimeLine = `${startLine} · ${timeRange}`
  return display
}

/**
 * Status chip text. Ports CalendarInvitePreviewBuilder.resolvedStatus, with the
 * iCalendar METHOD and VEVENT STATUS taking precedence over the subject
 * heuristics now that both are available. '' means no chip.
 */
export function calendarStatusLabel(event: CalendarEventData, subject: string | null): string {
  const normalizedSubject = subject?.trim().toLowerCase() ?? ''

  if (
    event.method === 'CANCEL' ||
    event.status === 'CANCELLED' ||
    normalizedSubject.startsWith('canceled:') ||
    normalizedSubject.startsWith('cancelled:')
  ) {
    return 'Cancelled'
  }

  if (normalizedSubject.startsWith('updated invitation:')) {
    return 'Updated'
  }

  if (event.method === 'REQUEST' || normalizedSubject.startsWith('invitation:')) {
    return 'Invitation'
  }

  return ''
}
