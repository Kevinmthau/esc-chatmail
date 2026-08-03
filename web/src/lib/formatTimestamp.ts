// Port of esc-chatmail/Utilities/TimestampFormatter.swift:
// today → "h:mm a"; yesterday → "Yesterday"; < 7 calendar days → weekday name;
// otherwise → "MM/dd/yy". The iOS daysDifference uses calendar-day components,
// so the buckets compare local calendar days, not 24h windows.

const timeFmt = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' })
const weekdayFmt = new Intl.DateTimeFormat('en-US', { weekday: 'long' })
const dateFmt = new Intl.DateTimeFormat('en-US', {
  month: '2-digit',
  day: '2-digit',
  year: '2-digit',
})

function startOfLocalDay(d: Date): number {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

const DAY_MS = 24 * 60 * 60 * 1000

export function formatTimestamp(epochMs: number, now: number = Date.now()): string {
  const date = new Date(epochMs)
  const nowDate = new Date(now)
  const dayDiff = Math.round((startOfLocalDay(nowDate) - startOfLocalDay(date)) / DAY_MS)

  if (dayDiff === 0) return timeFmt.format(date)
  if (dayDiff === 1) return 'Yesterday'
  if (dayDiff > 1 && dayDiff < 7) return weekdayFmt.format(date)
  return dateFmt.format(date)
}
