import { describe, expect, it } from 'vitest'
import { formatTimestamp } from './formatTimestamp'

// Fixed reference: Wednesday 2026-07-22 15:30 local time.
const NOW = new Date(2026, 6, 22, 15, 30).getTime()

describe('formatTimestamp', () => {
  it('formats today as h:mm a', () => {
    const at = new Date(2026, 6, 22, 9, 5).getTime()
    expect(formatTimestamp(at, NOW)).toMatch(/^9:05\sAM$/i)
  })

  it('formats yesterday as Yesterday', () => {
    const at = new Date(2026, 6, 21, 23, 59).getTime()
    expect(formatTimestamp(at, NOW)).toBe('Yesterday')
  })

  it('crosses the midnight boundary by calendar day, not 24h', () => {
    // 16 hours ago but yesterday's date.
    const at = new Date(2026, 6, 21, 23, 30).getTime()
    expect(formatTimestamp(at, NOW)).toBe('Yesterday')
  })

  it('formats 2-6 days ago as weekday name', () => {
    expect(formatTimestamp(new Date(2026, 6, 20, 12, 0).getTime(), NOW)).toBe('Monday')
    expect(formatTimestamp(new Date(2026, 6, 16, 12, 0).getTime(), NOW)).toBe('Thursday')
  })

  it('formats 7+ days ago as MM/dd/yy', () => {
    expect(formatTimestamp(new Date(2026, 6, 15, 12, 0).getTime(), NOW)).toBe('07/15/26')
  })

  it('formats future dates as MM/dd/yy (matches iOS fallthrough)', () => {
    expect(formatTimestamp(new Date(2026, 6, 25, 12, 0).getTime(), NOW)).toBe('07/25/26')
  })
})
