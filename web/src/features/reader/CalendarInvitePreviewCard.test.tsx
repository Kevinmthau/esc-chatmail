// Calendar invite card rendering from an extracted event.

import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { CalendarEventData } from '@/db/types'
import { PREVIEW_HEIGHT_CALENDAR } from '@/lib/constants'
import { CalendarInvitePreviewCard } from './CalendarInvitePreviewCard'

vi.mock('@tanstack/react-router', () => ({
  Link: ({ children, ...props }: { children?: ReactNode; 'aria-label'?: string }) => (
    <a data-testid="router-link" aria-label={props['aria-label']}>
      {children}
    </a>
  ),
}))

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

function renderCard(
  overrides: Partial<CalendarEventData> = {},
  subject = 'Invitation: Design sync',
) {
  return render(
    <CalendarInvitePreviewCard
      messageId="m1"
      event={event(overrides)}
      subject={subject}
      sender="Alice Smith"
    />,
  )
}

afterEach(cleanup)

describe('CalendarInvitePreviewCard', () => {
  it('renders the title, source, status, location, and organizer', () => {
    renderCard()
    expect(screen.getByText('Design sync')).toBeTruthy()
    expect(screen.getByText('Google Calendar')).toBeTruthy()
    expect(screen.getByText('Invitation')).toBeTruthy()
    expect(screen.getByText('Conference Room B')).toBeTruthy()
    expect(screen.getByText(/Hosted by/)).toBeTruthy()
    expect(screen.getByText('Open invite')).toBeTruthy()
  })

  it('renders a date rail from the event start', () => {
    const { container } = renderCard({ isAllDay: 1, startMs: Date.UTC(2026, 6, 4), endMs: 0 })
    expect(screen.getByText('JUL')).toBeTruthy()
    expect(screen.getByText('4')).toBeTruthy()
    expect(container.textContent).toContain('All day')
  })

  it('reserves its fixed height up front', () => {
    renderCard()
    const card = screen.getByTestId('calendar-invite-card')
    expect(card.style.height).toBe(`${PREVIEW_HEIGHT_CALENDAR}px`)
  })

  it('shows the cancelled chip for a CANCEL invite', () => {
    renderCard({ method: 'CANCEL', status: 'CANCELLED' }, 'Canceled: Design sync')
    expect(screen.getByText('Cancelled')).toBeTruthy()
  })

  it('omits the location and falls back to the sender as host', () => {
    renderCard({ location: '', organizer: '' })
    expect(screen.queryByText('Conference Room B')).toBeNull()
    expect(screen.getByText(/Hosted by/).textContent).toContain('Alice Smith')
  })

  it('titles an untitled event and links into the reader', () => {
    renderCard({ title: '' }, '')
    // Both the title fallback and the REQUEST status chip read "Invitation".
    expect(screen.getAllByText('Invitation')).toHaveLength(2)
    // The link's label carries the full date/time the compact clock row omits.
    expect(screen.getByLabelText(/^Open calendar invite: Invitation, .*Mar 18, 2026/)).toBeTruthy()
  })

  it('uses the video glyph for a Google Meet location', () => {
    const { container } = renderCard({ location: 'Google Meet' })
    expect(container.querySelector('[data-icon="video"]')).not.toBeNull()
    expect(container.querySelector('[data-icon="location"]')).toBeNull()
  })
})
