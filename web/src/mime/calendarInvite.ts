// Calendar-invite detection and iCalendar extraction.
//
// Detection ports esc-chatmail/Services/Preview/Shared/CalendarInviteSignals.swift
// (the single source of truth for the textual signals) plus
// Message.computeIsLikelyCalendarInvite (Services/Models/Message+Extensions.swift),
// branch for branch. One deliberate widening: iOS can only see a calendar part
// once it has been modelled as an Attachment, so its signal is
// `Attachment.isCalendarInviteAttachment`. Here the raw MIME tree is in hand, so
// an INLINE `text/calendar` part (the multipart/alternative sibling Google
// Calendar ships, which carries no filename or disposition and would never
// become an attachment row) counts too. Same signal, seen earlier.
//
// Extraction has no iOS counterpart: CalendarInvitePreviewBuilder scrapes the
// rendered "When / Where / Who" text block, while here the iCalendar part is
// available and authoritative. Everything below is defensive — a malformed
// VEVENT yields null so the message degrades to the generic preview card, and
// nothing in this module throws into sync.

import type { CalendarEventData } from '../db/types'
import type { GmailPart } from '../gmail/types'
import { base64UrlDecodeToString, decodeHtmlEntities, decodeTransferEncoding } from './decode'

// MARK: - Signals (CalendarInviteSignals.swift)

const GOOGLE_CALENDAR_MARKERS = [
  'google calendar',
  'calendar.google.com',
  'meet.google.com',
  'reply for ',
  'view all guest info',
]

const INVITE_SUBJECT_PREFIXES = ['invitation:', 'updated invitation:', 'canceled:', 'cancelled:']

/**
 * Invite field labels as they appear in flattened plain text, where each label
 * sits on its own line.
 */
const STRUCTURAL_TEXT_MARKERS = [
  '\nwhen\n',
  '\nwhere\n',
  '\nguests\n',
  '\nmore options\n',
  'yes no maybe',
]

/** CalendarInvitePreviewBuilder.resolvedSourceLabel's two outcomes. */
const GOOGLE_CALENDAR_SOURCE = 'Google Calendar'
const GENERIC_CALENDAR_SOURCE = 'Calendar'

/**
 * Cap on the text fed to the signal scan. Detection runs inside sync's
 * persist step on the main thread, and fetchLargeBody supports multi-megabyte
 * bodies; a real invite's signals live in the first few KB, while an
 * unbounded scan makes body length a sync-stall lever (the pattern below is
 * quadratic against text that keeps almost-matching).
 */
const SIGNAL_TEXT_CAP = 16 * 1024

// The gap between the weekday/month token and the time is bounded ({0,80}):
// semantically, a weekday forty lines away from a time is not a date-time
// signal, and an unbounded gap makes the scan O(n²) on 24-hour-clock text
// where the trailing am/pm never matches.
const DATE_TIME_PATTERN =
  /\b(?:mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b[\w\s,.:()\-–•]{0,80}\b\d{1,2}:\d{2}\s*(?:am|pm)\b/i

export function containsGoogleCalendarMarker(lowercasedText: string): boolean {
  return GOOGLE_CALENDAR_MARKERS.some((marker) => lowercasedText.includes(marker))
}

export function hasInviteSubjectPrefix(lowercasedSubject: string): boolean {
  return INVITE_SUBJECT_PREFIXES.some((prefix) => lowercasedSubject.startsWith(prefix))
}

export function containsDateTimeSignal(text: string): boolean {
  return DATE_TIME_PATTERN.test(text)
}

/** CalendarInviteSignals.normalizedSignalText. */
export function normalizedSignalText(text: string | null | undefined): string {
  if (text === null || text === undefined) return ''
  return decodeHtmlEntities(text)
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .replace(/\u00A0/g, ' ')
    .replace(/[ \t]+/g, ' ')
    .trim()
}

export interface CalendarInviteSignalInput {
  subject: string | null
  /** cleanedSnippet ?? snippet on iOS; the Gmail snippet here. */
  snippet: string | null
  /** Display text of the body (raw-source sanitized, HTML-derived when needed). */
  bodyText: string | null
  /** A `text/calendar`-ish MIME part exists anywhere in the payload. */
  hasCalendarPart: boolean
}

/** The lowercased subject/snippet/body blob every textual signal scans. */
function combinedSignalText(input: CalendarInviteSignalInput): string {
  return [
    normalizedSignalText(input.subject).toLowerCase(),
    normalizedSignalText(input.snippet).toLowerCase(),
    // Only the head of the body: see SIGNAL_TEXT_CAP.
    normalizedSignalText(input.bodyText?.slice(0, SIGNAL_TEXT_CAP)).toLowerCase(),
  ]
    .filter((part) => part.length > 0)
    .join('\n')
}

/** Message.computeIsLikelyCalendarInvite, branch for branch. */
export function isLikelyCalendarInvite(input: CalendarInviteSignalInput): boolean {
  const normalizedSubject = normalizedSignalText(input.subject).toLowerCase()
  const combinedText = combinedSignalText(input)

  const hasGoogleCalendarMarker = containsGoogleCalendarMarker(combinedText)
  const hasSubjectPrefix = hasInviteSubjectPrefix(normalizedSubject)
  const hasCalendarStructure =
    STRUCTURAL_TEXT_MARKERS.filter((marker) => combinedText.includes(marker)).length >= 2
  const hasDateSignal = containsDateTimeSignal(combinedText)

  if (hasGoogleCalendarMarker) {
    return true
  }

  if (input.hasCalendarPart && (hasSubjectPrefix || hasCalendarStructure || hasDateSignal)) {
    return true
  }

  return hasSubjectPrefix && hasCalendarStructure && hasDateSignal
}

// MARK: - Calendar MIME parts

/**
 * Attachment.isCalendarInviteAttachment on (mimeType, filename) — shared by
 * raw-part detection here and by the chat bubble, which hides matching
 * attachment tiles whenever the calendar card presents the same payload.
 */
export function isCalendarInviteAttachment(mimeType: string, filename: string): boolean {
  const mime = mimeType.trim().toLowerCase()
  const name = filename.trim().toLowerCase()
  return (
    mime.startsWith('text/calendar') ||
    mime === 'application/ics' ||
    mime === 'application/ical' ||
    mime === 'application/x-ical' ||
    name.endsWith('.ics')
  )
}

/** Attachment.isCalendarInviteAttachment, applied to a raw MIME part. */
function isCalendarPart(part: GmailPart): boolean {
  return isCalendarInviteAttachment(part.mimeType ?? '', part.filename ?? '')
}

/** `method=REQUEST` off a `text/calendar; method=REQUEST` mime type. */
function methodFromMimeType(mimeType: string | undefined): string {
  const match = /;\s*method\s*=\s*"?([A-Za-z]+)"?/.exec(mimeType ?? '')
  return match?.[1]?.toUpperCase() ?? ''
}

export interface CalendarParts {
  /** Any calendar part exists — the detection signal; never needs the bytes. */
  hasCalendarPart: boolean
  /** Decoded iCalendar documents from INLINE parts, in tree order. */
  documents: string[]
  /** METHOD parameter of the first calendar part that declares one. */
  method: string
}

/**
 * Walks the payload for calendar parts. Only inline `body.data` is decoded:
 * an oversized/attachment part would need an `attachments.get` round trip, and
 * the detection signal never needs the bytes.
 */
export function collectCalendarParts(payload: GmailPart | undefined): CalendarParts {
  const result: CalendarParts = { hasCalendarPart: false, documents: [], method: '' }
  if (payload === undefined) return result

  const walk = (part: GmailPart): void => {
    if (isCalendarPart(part)) {
      result.hasCalendarPart = true
      if (result.method === '') result.method = methodFromMimeType(part.mimeType)
      const data = part.body?.data
      if (data !== undefined) {
        const decoded = base64UrlDecodeToString(data)
        if (decoded !== null) {
          result.documents.push(decodeTransferEncoding(decoded, part.headers))
        }
      }
    }
    for (const subpart of part.parts ?? []) walk(subpart)
  }

  walk(payload)
  return result
}

// MARK: - iCalendar parsing (RFC 5545, minimal + defensive)

interface ICalProperty {
  name: string
  params: Map<string, string>
  value: string
}

/** Undoes RFC 5545 line folding (a continuation starts with space or tab). */
function unfold(document: string): string[] {
  const normalized = document.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
  const lines: string[] = []
  for (const raw of normalized.split('\n')) {
    const previousIndex = lines.length - 1
    const previous = lines[previousIndex]
    if ((raw.startsWith(' ') || raw.startsWith('\t')) && previous !== undefined) {
      lines[previousIndex] = previous + raw.slice(1)
    } else {
      lines.push(raw)
    }
  }
  return lines
}

/** Splits on a delimiter, ignoring delimiters inside double-quoted parameters. */
function splitOutsideQuotes(text: string, delimiter: string): string[] {
  const segments: string[] = []
  let current = ''
  let quoted = false
  for (const char of text) {
    if (char === '"') {
      quoted = !quoted
      current += char
    } else if (char === delimiter && !quoted) {
      segments.push(current)
      current = ''
    } else {
      current += char
    }
  }
  segments.push(current)
  return segments
}

function unescapeValue(value: string): string {
  // One pass, not chained replaces: RFC 5545 escapes must tokenize left to
  // right, or the second backslash of an escaped backslash (`\\`) followed by
  // an n would be re-read as `\n` and turn `C:\\nightly` into a newline.
  return value
    .replace(/\\([nN,;\\])/g, (_, escaped: string) =>
      escaped === 'n' || escaped === 'N' ? '\n' : escaped,
    )
    .trim()
}

/**
 * RFC 5545 DURATION (§3.3.6) → milliseconds; null when unparseable or zero.
 * Outlook commonly emits DTSTART+DURATION instead of DTEND (§3.6.1 allows
 * either), so without this an Outlook invite shows a start with no range.
 */
function parseICalDuration(value: string): number | null {
  const match = /^([+-]?)P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?)$/.exec(
    value.trim(),
  )
  if (match === null) return null
  const [, sign, weeks, days, hours, minutes, seconds] = match
  const num = (part: string | undefined): number => (part === undefined ? 0 : Number(part))
  const ms =
    num(weeks) * 604_800_000 +
    num(days) * 86_400_000 +
    num(hours) * 3_600_000 +
    num(minutes) * 60_000 +
    num(seconds) * 1_000
  if (ms === 0) return null
  return sign === '-' ? -ms : ms
}

function parseProperty(line: string): ICalProperty | null {
  let quoted = false
  let colonIndex = -1
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index]
    if (char === '"') {
      quoted = !quoted
    } else if (char === ':' && !quoted) {
      colonIndex = index
      break
    }
  }
  if (colonIndex === -1) return null

  const segments = splitOutsideQuotes(line.slice(0, colonIndex), ';')
  const name = (segments[0] ?? '').trim().toUpperCase()
  if (name.length === 0) return null

  const params = new Map<string, string>()
  for (const segment of segments.slice(1)) {
    const equalsIndex = segment.indexOf('=')
    if (equalsIndex === -1) continue
    const key = segment.slice(0, equalsIndex).trim().toUpperCase()
    const value = segment
      .slice(equalsIndex + 1)
      .trim()
      .replace(/^"|"$/g, '')
    if (key.length > 0) params.set(key, value)
  }

  return { name, params, value: line.slice(colonIndex + 1) }
}

// MARK: - Time zone math

/** Offset (ms) of `timeZone` from UTC at the given instant. */
function zoneOffsetMs(utcMs: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(new Date(utcMs))

  const field = (type: string): number => {
    const value = parts.find((part) => part.type === type)?.value
    return value === undefined ? 0 : Number(value)
  }

  const asUtc = Date.UTC(
    field('year'),
    field('month') - 1,
    field('day'),
    field('hour'),
    field('minute'),
    field('second'),
  )
  return asUtc - utcMs
}

/** True when `timeZone` is an identifier this runtime's ICU data understands. */
export function isSupportedTimeZone(timeZone: string): boolean {
  if (timeZone.length === 0) return false
  try {
    new Intl.DateTimeFormat('en-US', { timeZone })
    return true
  } catch {
    return false
  }
}

/**
 * Wall-clock fields in `timeZone` → epoch ms. Solved by taking the offset at a
 * first guess and re-solving once, which lands correctly on both sides of a DST
 * transition (the classic two-pass inversion).
 */
function wallClockToEpochMs(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second: number,
  timeZone: string,
): number {
  const guess = Date.UTC(year, month - 1, day, hour, minute, second)
  const firstOffset = zoneOffsetMs(guess, timeZone)
  const firstPass = guess - firstOffset
  const secondOffset = zoneOffsetMs(firstPass, timeZone)
  return secondOffset === firstOffset ? firstPass : guess - secondOffset
}

interface ParsedDateTime {
  ms: number
  isAllDay: boolean
  /** IANA identifier the value was expressed in; '' for UTC/floating. */
  timeZone: string
}

const ICAL_DATE_TIME = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/

/**
 * DATE / DATE-TIME value → instant.
 *
 * All-day values are anchored to UTC midnight and flagged; the card formats
 * them in UTC so "Mar 15" never slides a day for a reader west of Greenwich.
 * Floating values (no Z, no TZID) are local time by RFC 5545.
 */
function parseICalDateTime(property: ICalProperty): ParsedDateTime | null {
  const raw = property.value.trim()
  const match = ICAL_DATE_TIME.exec(raw)
  if (match === null) return null

  const [, yearText, monthText, dayText, hourText, minuteText, secondText, utcMarker] = match
  const year = Number(yearText)
  const month = Number(monthText)
  const day = Number(dayText)
  if (month < 1 || month > 12 || day < 1 || day > 31) return null

  const isDateOnly = hourText === undefined || property.params.get('VALUE') === 'DATE'
  if (isDateOnly) {
    return { ms: Date.UTC(year, month - 1, day), isAllDay: true, timeZone: '' }
  }

  const hour = Number(hourText)
  const minute = Number(minuteText)
  const second = Number(secondText)
  if (hour > 23 || minute > 59 || second > 60) return null

  if (utcMarker === 'Z') {
    return {
      ms: Date.UTC(year, month - 1, day, hour, minute, second),
      isAllDay: false,
      timeZone: '',
    }
  }

  const tzid = property.params.get('TZID') ?? ''
  if (tzid.length > 0 && isSupportedTimeZone(tzid)) {
    return {
      ms: wallClockToEpochMs(year, month, day, hour, minute, second, tzid),
      isAllDay: false,
      timeZone: tzid,
    }
  }

  // Floating (or an unknown TZID): local time on this device.
  return {
    ms: new Date(year, month - 1, day, hour, minute, second).getTime(),
    isAllDay: false,
    timeZone: '',
  }
}

// MARK: - Event extraction

/** CalendarInvitePreviewBuilder.isGoogleMeetLine + resolvedLocationLine. */
function normalizedLocation(location: string): string {
  const lowercased = location.toLowerCase()
  if (lowercased.includes('meet.google.com') || lowercased.includes('google meet')) {
    return 'Google Meet'
  }
  return location
}

/** ORGANIZER: prefer the CN parameter, else the mailto address. */
function organizerFrom(property: ICalProperty): string {
  const commonName = property.params.get('CN')?.trim() ?? ''
  if (commonName.length > 0) return commonName
  return property.value.trim().replace(/^mailto:/i, '')
}

/**
 * Extracts the first VEVENT of an iCalendar document. Returns null when the
 * document has no usable event: a start instant is the one hard requirement,
 * since the card is built around the date.
 */
export function parseICalendarEvent(document: string): CalendarEventData | null {
  let method = ''
  let prodId = ''
  let title = ''
  let location = ''
  let organizer = ''
  let status = ''
  let start: ParsedDateTime | null = null
  let end: ParsedDateTime | null = null
  let durationMs: number | null = null
  // Component stack, not a boolean: VEVENTs nest sub-components (VALARM most
  // commonly), and an email-alert alarm carries its own RFC-legal SUMMARY that
  // must not overwrite the event's title. Event properties are read only while
  // the VEVENT itself is the innermost open component.
  const componentStack: string[] = []
  let sawEvent = false

  for (const line of unfold(document)) {
    const property = parseProperty(line)
    if (property === null) continue

    if (property.name === 'BEGIN') {
      const component = property.value.trim().toUpperCase()
      // Only the first VEVENT is described; later ones are recurrence
      // overrides or additional events the card has no room for.
      if (component === 'VEVENT' && sawEvent) break
      if (component === 'VEVENT') sawEvent = true
      componentStack.push(component)
      continue
    }
    if (property.name === 'END') {
      componentStack.pop()
      continue
    }

    if (componentStack.at(-1) !== 'VEVENT') {
      if (property.name === 'METHOD') method = property.value.trim().toUpperCase()
      if (property.name === 'PRODID') prodId = property.value.toLowerCase()
      continue
    }

    switch (property.name) {
      case 'SUMMARY':
        title = unescapeValue(property.value)
        break
      case 'LOCATION':
        location = normalizedLocation(unescapeValue(property.value))
        break
      case 'ORGANIZER':
        organizer = organizerFrom(property)
        break
      case 'STATUS':
        status = property.value.trim().toUpperCase()
        break
      case 'DTSTART':
        start = parseICalDateTime(property)
        break
      case 'DTEND':
        end = parseICalDateTime(property)
        break
      case 'DURATION':
        durationMs = parseICalDuration(property.value)
        break
      default:
        break
    }
  }

  if (start === null) return null

  // DTEND wins when both are present (RFC 5545 forbids the combination);
  // DTSTART+DURATION is Outlook's common spelling of the same range.
  const endMs =
    end !== null ? end.ms : durationMs !== null && durationMs > 0 ? start.ms + durationMs : 0

  return {
    title,
    startMs: start.ms,
    endMs: endMs > start.ms ? endMs : 0,
    timeZone: start.timeZone,
    isAllDay: start.isAllDay ? 1 : 0,
    location,
    organizer,
    method,
    status,
    source: containsGoogleCalendarMarker(prodId) ? GOOGLE_CALENDAR_SOURCE : GENERIC_CALENDAR_SOURCE,
  }
}

// MARK: - Message-level entry point

export interface CalendarInviteAnalysis {
  isLikelyCalendarInvite: boolean
  /** Null when there is no iCalendar part, or none of them parsed. */
  event: CalendarEventData | null
}

/** Subject with the Google Calendar invite prefix and " @ <when>" tail removed. */
export function invitedSubjectTitle(subject: string | null): string {
  const normalized = normalizedSignalText(subject)
  if (normalized.length === 0) return ''
  const stripped = normalized.replace(
    /^(?:updated\s+invitation|invitation|canceled|cancelled):\s*/i,
    '',
  )
  const separatorIndex = stripped.indexOf(' @ ')
  return (separatorIndex === -1 ? stripped : stripped.slice(0, separatorIndex)).trim()
}

export interface CalendarInviteAnalysisInput {
  payload: GmailPart | undefined
  subject: string | null
  snippet: string | null
  bodyText: string | null
}

/**
 * The message-level verdict plus the extracted event. Never throws: a MIME tree
 * or iCalendar document this cannot make sense of degrades to
 * `{ isLikelyCalendarInvite, event: null }`, which routes to the generic
 * preview card instead of the calendar card.
 */
export function analyzeCalendarInvite(input: CalendarInviteAnalysisInput): CalendarInviteAnalysis {
  let parts: CalendarParts = { hasCalendarPart: false, documents: [], method: '' }
  try {
    parts = collectCalendarParts(input.payload)
  } catch {
    // A malformed part tree costs the calendar part signal, nothing else.
  }

  const signalInput: CalendarInviteSignalInput = {
    subject: input.subject,
    snippet: input.snippet,
    bodyText: input.bodyText,
    hasCalendarPart: parts.hasCalendarPart,
  }
  const verdict = isLikelyCalendarInvite(signalInput)
  const signalText = combinedSignalText(signalInput)

  let event: CalendarEventData | null = null
  for (const document of parts.documents) {
    try {
      event = parseICalendarEvent(document)
    } catch {
      event = null
    }
    if (event !== null) break
  }

  if (event !== null) {
    if (event.title.length === 0) event.title = invitedSubjectTitle(input.subject)
    if (event.method.length === 0) event.method = parts.method
    // resolvedSourceLabel: the message text is the same evidence the iOS
    // builder uses, and it catches Google invites relayed through a PRODID that
    // does not name the product.
    if (event.source !== GOOGLE_CALENDAR_SOURCE && containsGoogleCalendarMarker(signalText)) {
      event.source = GOOGLE_CALENDAR_SOURCE
    }
  }

  return { isLikelyCalendarInvite: verdict, event }
}
