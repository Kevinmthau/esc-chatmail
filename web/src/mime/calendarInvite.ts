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

// MARK: - Non-IANA TZIDs (Exchange / Outlook)

/**
 * Windows time-zone names → IANA, the CLDR windowsZones "001" rows for every
 * zone Exchange emits in the Americas, Europe/Africa and Asia-Pacific. Outlook
 * writes `TZID=Eastern Standard Time` (the Windows registry key, DST and all)
 * rather than an IANA name, and Intl refuses it. Keys are lowercased.
 */
const WINDOWS_TIME_ZONE_ALIASES: ReadonlyMap<string, string> = new Map(
  Object.entries({
    // Americas
    'Dateline Standard Time': 'Etc/GMT+12',
    'UTC-11': 'Etc/GMT+11',
    'Aleutian Standard Time': 'America/Adak',
    'Hawaiian Standard Time': 'Pacific/Honolulu',
    'Marquesas Standard Time': 'Pacific/Marquesas',
    'Alaskan Standard Time': 'America/Anchorage',
    'UTC-09': 'Etc/GMT+9',
    'Pacific Standard Time (Mexico)': 'America/Tijuana',
    'UTC-08': 'Etc/GMT+8',
    'Pacific Standard Time': 'America/Los_Angeles',
    'US Mountain Standard Time': 'America/Phoenix',
    'Mountain Standard Time (Mexico)': 'America/Mazatlan',
    'Mountain Standard Time': 'America/Denver',
    'Yukon Standard Time': 'America/Whitehorse',
    'Central America Standard Time': 'America/Guatemala',
    'Central Standard Time': 'America/Chicago',
    'Easter Island Standard Time': 'Pacific/Easter',
    'Central Standard Time (Mexico)': 'America/Mexico_City',
    'Canada Central Standard Time': 'America/Regina',
    'SA Pacific Standard Time': 'America/Bogota',
    'Eastern Standard Time (Mexico)': 'America/Cancun',
    'Eastern Standard Time': 'America/New_York',
    'Haiti Standard Time': 'America/Port-au-Prince',
    'Cuba Standard Time': 'America/Havana',
    'US Eastern Standard Time': 'America/Indiana/Indianapolis',
    'Turks And Caicos Standard Time': 'America/Grand_Turk',
    'Paraguay Standard Time': 'America/Asuncion',
    'Atlantic Standard Time': 'America/Halifax',
    'Venezuela Standard Time': 'America/Caracas',
    'Central Brazilian Standard Time': 'America/Cuiaba',
    'SA Western Standard Time': 'America/La_Paz',
    'Pacific SA Standard Time': 'America/Santiago',
    'Newfoundland Standard Time': 'America/St_Johns',
    'Tocantins Standard Time': 'America/Araguaina',
    'E. South America Standard Time': 'America/Sao_Paulo',
    'SA Eastern Standard Time': 'America/Cayenne',
    'Argentina Standard Time': 'America/Argentina/Buenos_Aires',
    'Montevideo Standard Time': 'America/Montevideo',
    'Magallanes Standard Time': 'America/Punta_Arenas',
    'Saint Pierre Standard Time': 'America/Miquelon',
    'Bahia Standard Time': 'America/Bahia',
    'UTC-02': 'Etc/GMT+2',
    'Greenland Standard Time': 'America/Godthab',
    'Azores Standard Time': 'Atlantic/Azores',
    'Cape Verde Standard Time': 'Atlantic/Cape_Verde',
    UTC: 'Etc/UTC',
    // Europe / Africa / Middle East
    'GMT Standard Time': 'Europe/London',
    'Greenwich Standard Time': 'Atlantic/Reykjavik',
    'Sao Tome Standard Time': 'Africa/Sao_Tome',
    'Morocco Standard Time': 'Africa/Casablanca',
    'W. Europe Standard Time': 'Europe/Berlin',
    'Central Europe Standard Time': 'Europe/Budapest',
    'Romance Standard Time': 'Europe/Paris',
    'Central European Standard Time': 'Europe/Warsaw',
    'W. Central Africa Standard Time': 'Africa/Lagos',
    'GTB Standard Time': 'Europe/Bucharest',
    'Middle East Standard Time': 'Asia/Beirut',
    'Egypt Standard Time': 'Africa/Cairo',
    'E. Europe Standard Time': 'Europe/Chisinau',
    'West Bank Standard Time': 'Asia/Hebron',
    'South Africa Standard Time': 'Africa/Johannesburg',
    'FLE Standard Time': 'Europe/Kiev',
    'Israel Standard Time': 'Asia/Jerusalem',
    'South Sudan Standard Time': 'Africa/Juba',
    'Kaliningrad Standard Time': 'Europe/Kaliningrad',
    'Sudan Standard Time': 'Africa/Khartoum',
    'Libya Standard Time': 'Africa/Tripoli',
    'Namibia Standard Time': 'Africa/Windhoek',
    'Jordan Standard Time': 'Asia/Amman',
    'Arabic Standard Time': 'Asia/Baghdad',
    'Syria Standard Time': 'Asia/Damascus',
    'Turkey Standard Time': 'Europe/Istanbul',
    'Arab Standard Time': 'Asia/Riyadh',
    'Belarus Standard Time': 'Europe/Minsk',
    'Russian Standard Time': 'Europe/Moscow',
    'E. Africa Standard Time': 'Africa/Nairobi',
    'Volgograd Standard Time': 'Europe/Volgograd',
    'Iran Standard Time': 'Asia/Tehran',
    'Arabian Standard Time': 'Asia/Dubai',
    'Astrakhan Standard Time': 'Europe/Astrakhan',
    'Azerbaijan Standard Time': 'Asia/Baku',
    'Russia Time Zone 3': 'Europe/Samara',
    'Mauritius Standard Time': 'Indian/Mauritius',
    'Saratov Standard Time': 'Europe/Saratov',
    'Georgian Standard Time': 'Asia/Tbilisi',
    'Caucasus Standard Time': 'Asia/Yerevan',
    'Afghanistan Standard Time': 'Asia/Kabul',
    // Asia-Pacific
    'West Asia Standard Time': 'Asia/Tashkent',
    'Ekaterinburg Standard Time': 'Asia/Yekaterinburg',
    'Pakistan Standard Time': 'Asia/Karachi',
    'Qyzylorda Standard Time': 'Asia/Qyzylorda',
    'Astana Standard Time': 'Asia/Almaty',
    'India Standard Time': 'Asia/Kolkata',
    'Sri Lanka Standard Time': 'Asia/Colombo',
    'Nepal Standard Time': 'Asia/Kathmandu',
    'Central Asia Standard Time': 'Asia/Bishkek',
    'Bangladesh Standard Time': 'Asia/Dhaka',
    'Omsk Standard Time': 'Asia/Omsk',
    'Myanmar Standard Time': 'Asia/Yangon',
    'SE Asia Standard Time': 'Asia/Bangkok',
    'Altai Standard Time': 'Asia/Barnaul',
    'W. Mongolia Standard Time': 'Asia/Hovd',
    'North Asia Standard Time': 'Asia/Krasnoyarsk',
    'N. Central Asia Standard Time': 'Asia/Novosibirsk',
    'Tomsk Standard Time': 'Asia/Tomsk',
    'China Standard Time': 'Asia/Shanghai',
    'North Asia East Standard Time': 'Asia/Irkutsk',
    'Singapore Standard Time': 'Asia/Singapore',
    'W. Australia Standard Time': 'Australia/Perth',
    'Taipei Standard Time': 'Asia/Taipei',
    'Ulaanbaatar Standard Time': 'Asia/Ulaanbaatar',
    'Aus Central W. Standard Time': 'Australia/Eucla',
    'Transbaikal Standard Time': 'Asia/Chita',
    'Tokyo Standard Time': 'Asia/Tokyo',
    'North Korea Standard Time': 'Asia/Pyongyang',
    'Korea Standard Time': 'Asia/Seoul',
    'Yakutsk Standard Time': 'Asia/Yakutsk',
    'Cen. Australia Standard Time': 'Australia/Adelaide',
    'AUS Central Standard Time': 'Australia/Darwin',
    'E. Australia Standard Time': 'Australia/Brisbane',
    'AUS Eastern Standard Time': 'Australia/Sydney',
    'West Pacific Standard Time': 'Pacific/Port_Moresby',
    'Tasmania Standard Time': 'Australia/Hobart',
    'Vladivostok Standard Time': 'Asia/Vladivostok',
    'Lord Howe Standard Time': 'Australia/Lord_Howe',
    'Bougainville Standard Time': 'Pacific/Bougainville',
    'Russia Time Zone 10': 'Asia/Srednekolymsk',
    'Magadan Standard Time': 'Asia/Magadan',
    'Norfolk Standard Time': 'Pacific/Norfolk',
    'Sakhalin Standard Time': 'Asia/Sakhalin',
    'Central Pacific Standard Time': 'Pacific/Guadalcanal',
    'Russia Time Zone 11': 'Asia/Kamchatka',
    'New Zealand Standard Time': 'Pacific/Auckland',
    'UTC+12': 'Etc/GMT-12',
    'Fiji Standard Time': 'Pacific/Fiji',
    'Chatham Islands Standard Time': 'Pacific/Chatham',
    'UTC+13': 'Etc/GMT-13',
    'Tonga Standard Time': 'Pacific/Tongatapu',
    'Samoa Standard Time': 'Pacific/Apia',
    'Line Islands Standard Time': 'Pacific/Kiritimati',
  }).map(([windowsName, iana]) => [windowsName.toLowerCase(), iana]),
)

/** IANA name for a Windows TZID this runtime can format in; null otherwise. */
export function ianaAliasForTimeZone(tzid: string): string | null {
  const alias = WINDOWS_TIME_ZONE_ALIASES.get(tzid.trim().toLowerCase())
  return alias !== undefined && isSupportedTimeZone(alias) ? alias : null
}

interface WallClock {
  year: number
  month: number
  day: number
  hour: number
  minute: number
  second: number
}

/** FREQ=YEARLY RRULE as VTIMEZONE observances use it: one onset per year. */
interface YearlyOnsetRule {
  month: number
  /** 0 (Sunday) – 6; null when the rule names a month day instead. */
  weekday: number | null
  /** 1-based from the month start, negative from its end; null with monthDays. */
  ordinal: number | null
  /** BYMONTHDAY candidates (ascending); the first on `weekday` wins. */
  monthDays: number[]
  /** UNTIL as an instant; null when the rule is open-ended. */
  untilMs: number | null
}

/** One STANDARD or DAYLIGHT observance of a VTIMEZONE. */
interface TimeZoneObservance {
  /** DTSTART: local wall clock of the first onset, read in `offsetFromMs`. */
  start: WallClock
  offsetFromMs: number
  offsetToMs: number
  /** Null when the observance happens once, at `start`. */
  rule: YearlyOnsetRule | null
}

interface TimeZoneComponent {
  observances: TimeZoneObservance[]
}

/** `+0530` / `-05` / `-050030` → ms east of UTC; null when malformed. */
function parseUtcOffsetMs(value: string): number | null {
  const match = /^([+-])(\d{2})(\d{2})?(\d{2})?$/.exec(value.trim())
  if (match === null) return null
  const [, sign, hours, minutes, seconds] = match
  const magnitude =
    Number(hours) * 3_600_000 + Number(minutes ?? '0') * 60_000 + Number(seconds ?? '0') * 1_000
  return sign === '-' ? -magnitude : magnitude
}

function parseWallClock(value: string): WallClock | null {
  const match = ICAL_DATE_TIME.exec(value.trim())
  if (match === null) return null
  const [, year, month, day, hour, minute, second] = match
  return {
    year: Number(year),
    month: Number(month),
    day: Number(day),
    hour: Number(hour ?? '0'),
    minute: Number(minute ?? '0'),
    second: Number(second ?? '0'),
  }
}

function wallClockAsUtcMs(wall: WallClock): number {
  return Date.UTC(wall.year, wall.month - 1, wall.day, wall.hour, wall.minute, wall.second)
}

const WEEKDAY_CODES = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA']

/**
 * The yearly transition rule Outlook writes (`FREQ=YEARLY;BYDAY=2SU;BYMONTH=3`)
 * plus the BYMONTHDAY spelling Apple uses (`BYDAY=SU;BYMONTHDAY=8,9,…,14`).
 * Anything else yields null and the observance is read as a single onset.
 */
function parseYearlyOnsetRule(value: string, offsetFromMs: number): YearlyOnsetRule | null {
  const fields = new Map<string, string>()
  for (const segment of value.split(';')) {
    const equalsIndex = segment.indexOf('=')
    if (equalsIndex === -1) continue
    fields.set(segment.slice(0, equalsIndex).trim().toUpperCase(), segment.slice(equalsIndex + 1))
  }
  if (fields.get('FREQ')?.trim().toUpperCase() !== 'YEARLY') return null

  const month = Number(fields.get('BYMONTH'))
  if (!Number.isInteger(month) || month < 1 || month > 12) return null

  const monthDays = (fields.get('BYMONTHDAY') ?? '')
    .split(',')
    .map((day) => Number(day))
    .filter((day) => Number.isInteger(day) && day >= 1 && day <= 31)
    .sort((a, b) => a - b)

  let weekday: number | null = null
  let ordinal: number | null = null
  const byDay = fields.get('BYDAY')?.trim().toUpperCase() ?? ''
  if (byDay.length > 0) {
    const dayMatch = /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/.exec(byDay)
    if (dayMatch === null) return null
    weekday = WEEKDAY_CODES.indexOf(dayMatch[2] ?? '')
    ordinal = dayMatch[1] === undefined ? null : Number(dayMatch[1])
    if (ordinal === 0) return null
  }
  if (weekday === null && monthDays.length === 0) return null
  if (weekday !== null && ordinal === null && monthDays.length === 0) return null

  let untilMs: number | null = null
  const until = fields.get('UNTIL')?.trim() ?? ''
  if (until.length > 0) {
    const untilWall = parseWallClock(until)
    if (untilWall === null) return null
    untilMs = wallClockAsUtcMs(untilWall) - (until.endsWith('Z') ? 0 : offsetFromMs)
  }

  return { month, weekday, ordinal, monthDays, untilMs }
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate()
}

function weekdayOf(year: number, month: number, day: number): number {
  return new Date(Date.UTC(year, month - 1, day)).getUTCDay()
}

/** Day of month the rule lands on in `year`; null when the month has none. */
function ruleDayOfMonth(rule: YearlyOnsetRule, year: number): number | null {
  const lastDay = daysInMonth(year, rule.month)
  if (rule.weekday === null) {
    const [first] = rule.monthDays
    return first !== undefined && first <= lastDay ? first : null
  }
  if (rule.ordinal === null) {
    return (
      rule.monthDays.find(
        (day) => day <= lastDay && weekdayOf(year, rule.month, day) === rule.weekday,
      ) ?? null
    )
  }
  let day: number
  if (rule.ordinal > 0) {
    const firstWeekday = weekdayOf(year, rule.month, 1)
    day = 1 + ((rule.weekday - firstWeekday + 7) % 7) + (rule.ordinal - 1) * 7
  } else {
    const lastWeekday = weekdayOf(year, rule.month, lastDay)
    day = lastDay - ((lastWeekday - rule.weekday + 7) % 7) + (rule.ordinal + 1) * 7
  }
  return day >= 1 && day <= lastDay ? day : null
}

/**
 * Instants (UTC ms) at which `observance` takes effect: its DTSTART (the
 * first onset by definition, even when a rule follows) plus the rule's onset
 * in each of the years asked.
 */
function observanceOnsetsMs(observance: TimeZoneObservance, years: readonly number[]): number[] {
  const { start, rule, offsetFromMs } = observance
  const onsets = [wallClockAsUtcMs(start) - offsetFromMs]
  if (rule === null) return onsets
  for (const year of years) {
    if (year < start.year) continue
    const day = ruleDayOfMonth(rule, year)
    if (day === null) continue
    const onsetMs =
      Date.UTC(year, rule.month - 1, day, start.hour, start.minute, start.second) - offsetFromMs
    if (rule.untilMs !== null && onsetMs > rule.untilMs) continue
    onsets.push(onsetMs)
  }
  return onsets
}

interface ZoneTransition {
  onsetMs: number
  offsetFromMs: number
  offsetToMs: number
}

/**
 * Offset in effect at `instantMs`: TZOFFSETTO of the latest transition at or
 * before it. Before every transition (an event older than the zone's first
 * rule) the earliest transition's TZOFFSETFROM is the only offset the
 * document declares for that era.
 */
function offsetInEffectMs(transitions: readonly ZoneTransition[], instantMs: number): number {
  let offset = transitions[0]?.offsetFromMs ?? 0
  for (const transition of transitions) {
    if (transition.onsetMs > instantMs) break
    offset = transition.offsetToMs
  }
  return offset
}

/**
 * Wall clock in a VTIMEZONE → epoch ms. Each TZOFFSETTO the zone declares is
 * a candidate reading of the wall clock, and a reading holds when that
 * offset is the one in effect at the instant it yields. The fall-back hour
 * yields two holding readings; the first occurrence wins, as ICU and
 * Foundation read it (and as wallClockToEpochMs lands for the US zones
 * Exchange emits most). The spring-forward hour yields none; it is carried
 * forward by the gap's length, as ZonedDateTime does, rather than refused.
 */
function epochMsFromTimeZoneComponent(zone: TimeZoneComponent, wall: WallClock): number | null {
  if (zone.observances.length === 0) return null

  const wallUtcMs = wallClockAsUtcMs(wall)
  // Both neighbouring years: the previous year's last transition is the one
  // in effect in January, and applying an offset can carry a New Year's Eve
  // wall clock across a January onset.
  const years = [wall.year - 1, wall.year, wall.year + 1]
  const transitions: ZoneTransition[] = []
  for (const observance of zone.observances) {
    for (const onsetMs of observanceOnsetsMs(observance, years)) {
      transitions.push({
        onsetMs,
        offsetFromMs: observance.offsetFromMs,
        offsetToMs: observance.offsetToMs,
      })
    }
  }
  transitions.sort((a, b) => a.onsetMs - b.onsetMs)

  const candidateOffsets = [...new Set(zone.observances.map((observance) => observance.offsetToMs))]
  const instants = candidateOffsets.map((offset) => wallUtcMs - offset)
  const holding = instants.filter(
    (instant) => offsetInEffectMs(transitions, instant) === wallUtcMs - instant,
  )
  return holding.length > 0 ? Math.min(...holding) : Math.max(...instants)
}

/**
 * The document's VTIMEZONE components keyed by TZID. Only the observances
 * are modelled (DTSTART, TZOFFSETFROM/TO, RRULE); RDATE lists, which Outlook
 * does not write, are ignored.
 */
function collectTimeZoneComponents(lines: readonly string[]): Map<string, TimeZoneComponent> {
  const zones = new Map<string, TimeZoneComponent>()
  const componentStack: string[] = []
  let tzid = ''
  let observances: TimeZoneObservance[] = []
  let start: WallClock | null = null
  let offsetFromMs: number | null = null
  let offsetToMs: number | null = null
  let rrule = ''

  for (const line of lines) {
    const property = parseProperty(line)
    if (property === null) continue

    if (property.name === 'BEGIN') {
      const component = property.value.trim().toUpperCase()
      componentStack.push(component)
      if (component === 'VTIMEZONE') {
        tzid = ''
        observances = []
      } else if (component === 'STANDARD' || component === 'DAYLIGHT') {
        start = null
        offsetFromMs = null
        offsetToMs = null
        rrule = ''
      }
      continue
    }

    if (property.name === 'END') {
      const component = componentStack.pop()
      if (component === 'STANDARD' || component === 'DAYLIGHT') {
        if (start !== null && offsetFromMs !== null && offsetToMs !== null) {
          observances.push({
            start,
            offsetFromMs,
            offsetToMs,
            rule: rrule.length > 0 ? parseYearlyOnsetRule(rrule, offsetFromMs) : null,
          })
        }
      } else if (component === 'VTIMEZONE' && tzid.length > 0 && observances.length > 0) {
        zones.set(tzid, { observances })
      }
      continue
    }

    const innermost = componentStack.at(-1)
    if (innermost === 'VTIMEZONE') {
      if (property.name === 'TZID') tzid = property.value.trim()
      continue
    }
    if (innermost !== 'STANDARD' && innermost !== 'DAYLIGHT') continue
    if (componentStack.at(-2) !== 'VTIMEZONE') continue

    switch (property.name) {
      case 'DTSTART':
        start = parseWallClock(property.value)
        break
      case 'TZOFFSETFROM':
        offsetFromMs = parseUtcOffsetMs(property.value)
        break
      case 'TZOFFSETTO':
        offsetToMs = parseUtcOffsetMs(property.value)
        break
      case 'RRULE':
        rrule = property.value.trim()
        break
      default:
        break
    }
  }

  return zones
}

const NO_TIME_ZONES: ReadonlyMap<string, TimeZoneComponent> = new Map()

interface ParsedDateTime {
  ms: number
  isAllDay: boolean
  /**
   * Zone the value was expressed in; '' for UTC/floating. An IANA identifier
   * when the TZID is one or aliases to one; a TZID resolved only through the
   * document's VTIMEZONE keeps its own name. The card never formats in this
   * zone (formatCalendarEvent guards every Intl use with isSupportedTimeZone);
   * it compares it to the reader's zone to decide whether to name the zone,
   * and a foreign name is exactly the cue a converted time needs.
   */
  timeZone: string
}

const ICAL_DATE_TIME = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/

/**
 * DATE / DATE-TIME value → instant.
 *
 * All-day values are anchored to UTC midnight and flagged; the card formats
 * them in UTC so "Mar 15" never slides a day for a reader west of Greenwich.
 * Floating values (no Z, no TZID) are local time by RFC 5545.
 *
 * A TZID Intl does not know is resolved from the document's own VTIMEZONE
 * first (Exchange ships one with every Windows-named TZID, and it is the
 * sender's authoritative offset table), then through the Windows→IANA alias
 * table, and only then read as floating: before this an Outlook invite's
 * wall clock was silently reinterpreted in the reader's zone, hours off for
 * anyone outside the sender's, with no zone label to flag it.
 */
function parseICalDateTime(
  property: ICalProperty,
  timeZones: ReadonlyMap<string, TimeZoneComponent> = NO_TIME_ZONES,
): ParsedDateTime | null {
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
  if (tzid.length > 0) {
    if (isSupportedTimeZone(tzid)) {
      return {
        ms: wallClockToEpochMs(year, month, day, hour, minute, second, tzid),
        isAllDay: false,
        timeZone: tzid,
      }
    }

    const alias = ianaAliasForTimeZone(tzid)
    const component = timeZones.get(tzid)
    if (component !== undefined) {
      const ms = epochMsFromTimeZoneComponent(component, {
        year,
        month,
        day,
        hour,
        minute,
        second,
      })
      if (ms !== null) {
        return { ms, isAllDay: false, timeZone: alias ?? tzid }
      }
    }

    if (alias !== null) {
      return {
        ms: wallClockToEpochMs(year, month, day, hour, minute, second, alias),
        isAllDay: false,
        timeZone: alias,
      }
    }
  }

  // Floating (or a TZID nothing above could resolve): local time on this device.
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

  const lines = unfold(document)
  // Pre-scanned: RFC 5545 orders components freely, and the VTIMEZONE a
  // DTSTART's TZID refers to may follow the VEVENT.
  const timeZones = collectTimeZoneComponents(lines)

  for (const line of lines) {
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
        start = parseICalDateTime(property, timeZones)
        break
      case 'DTEND':
        end = parseICalDateTime(property, timeZones)
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
