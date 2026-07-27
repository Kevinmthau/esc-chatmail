// Calendar-invite preview card — port of
// esc-chatmail/Views/Components/EmailPreview/CalendarInvitePreviewCard.swift:
// source label + status chip header, a blue date rail, then title, time,
// location and organizer rows over an "Open invite" footer. Like the generic
// HtmlPreviewCard the whole surface is one overlay link into the full reader.
//
// Everything it renders comes from the already-extracted event, so the card
// paints complete on first frame — but the height is pinned regardless, since
// the chat scroll engine measures rows and must not see them resize.

import { Link } from '@tanstack/react-router'
import type { CalendarEventData } from '@/db/types'
import { PREVIEW_HEIGHT_CALENDAR } from '@/lib/constants'
import {
  calendarStatusLabel,
  formatCalendarEvent,
  type CalendarEventDisplay,
} from '@/lib/formatCalendarEvent'

interface CalendarInvitePreviewCardProps {
  messageId: string
  event: CalendarEventData
  /** Message subject; the status fallback when the iCalendar METHOD is absent. */
  subject: string
  /** Sender display line, used when the invite names no organizer. */
  sender: string
}

export function CalendarInvitePreviewCard({
  messageId,
  event,
  subject,
  sender,
}: CalendarInvitePreviewCardProps) {
  const display = formatCalendarEvent(event)
  const status = calendarStatusLabel(event, subject)
  const title = event.title.trim().length > 0 ? event.title.trim() : 'Invitation'
  const source = event.source.trim().length > 0 ? event.source.trim() : 'Calendar'
  const organizer = event.organizer.trim().length > 0 ? event.organizer.trim() : sender.trim()

  return (
    <div
      data-testid="calendar-invite-card"
      style={{ height: PREVIEW_HEIGHT_CALENDAR }}
      className="border-border bg-bg-elev rounded-card relative flex flex-col overflow-hidden border p-3.5"
    >
      <div className="flex items-center gap-2">
        <span className="text-accent font-rounded truncate text-[11px] font-semibold">
          {source}
        </span>
        {status.length > 0 && (
          <span className="text-fg-muted rounded-chip font-rounded bg-fg/10 ml-auto shrink-0 px-2.5 py-1 text-[11px] font-semibold">
            {status}
          </span>
        )}
      </div>

      <div className="mt-3 flex min-h-0 flex-1 gap-3.5">
        <DateRail display={display} />

        {/* min-w-0 + flex-1: without both, a long title sizes the column to
            max-content and spills past the card instead of wrapping. */}
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          {/* shrink-0 everywhere below: the column is inside a fixed-height
              card, and flex shrink would silently clip the clamped title's
              second line rather than leave it out. */}
          <p className="text-fg font-rounded line-clamp-2 shrink-0 text-[17px] font-semibold leading-tight">
            {title}
          </p>

          <MetaRow icon={<ClockIcon />} className="text-fg font-semibold">
            {display.timeLine}
          </MetaRow>

          {event.location.trim().length > 0 && (
            <MetaRow
              icon={event.location.toLowerCase().includes('meet') ? <VideoIcon /> : <PinIcon />}
              className="text-fg-muted font-medium"
            >
              {event.location.trim()}
            </MetaRow>
          )}

          {organizer.length > 0 && (
            <MetaRow icon={<PeopleIcon />} className="text-fg-muted">
              Hosted by {organizer}
            </MetaRow>
          )}
        </div>
      </div>

      <span className="text-accent font-rounded mt-2 shrink-0 text-xs font-semibold">
        Open invite
      </span>

      <Link
        from="/chats/$conversationId"
        to="."
        search={(prev) => ({ ...prev, reader: messageId })}
        aria-label={`Open calendar invite: ${title}, ${display.dateTimeLine}`}
        className="absolute inset-0"
      />
    </div>
  )
}

function DateRail({ display }: { display: CalendarEventDisplay }) {
  return (
    <div className="from-accent to-accent/75 font-rounded flex h-[92px] w-[70px] shrink-0 flex-col items-center justify-center gap-0.5 rounded-2xl bg-gradient-to-b text-white">
      <span className="text-xs font-semibold opacity-90">{display.monthSymbol}</span>
      <span className="text-[30px] font-bold leading-none">{display.dayNumber}</span>
      {display.weekdaySymbol.length > 0 && (
        <span className="text-[11px] font-semibold opacity-90">{display.weekdaySymbol}</span>
      )}
    </div>
  )
}

function MetaRow({
  icon,
  className,
  children,
}: {
  icon: React.ReactNode
  className?: string
  children: React.ReactNode
}) {
  return (
    <div className={`flex min-w-0 shrink-0 items-start gap-1.5 text-[13px] ${className ?? ''}`}>
      <span className="mt-px shrink-0">{icon}</span>
      <span className="line-clamp-1 min-w-0">{children}</span>
    </div>
  )
}

// --- Glyphs (inline SVG, matching features/conversations/icons.tsx) ----------

function glyphProps(name: string) {
  return {
    viewBox: '0 0 24 24',
    fill: 'none' as const,
    stroke: 'currentColor',
    strokeWidth: 2,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    'aria-hidden': true,
    'data-icon': name,
    className: 'size-3.5',
  }
}

function ClockIcon() {
  return (
    <svg {...glyphProps('clock')}>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3.5 2" />
    </svg>
  )
}

function PinIcon() {
  return (
    <svg {...glyphProps('location')}>
      <path d="M12 21s7-5.6 7-11a7 7 0 1 0-14 0c0 5.4 7 11 7 11z" />
      <circle cx="12" cy="10" r="2.5" />
    </svg>
  )
}

function VideoIcon() {
  return (
    <svg {...glyphProps('video')}>
      <rect x="3" y="6" width="12" height="12" rx="2" />
      <path d="m15 10 6-3v10l-6-3" />
    </svg>
  )
}

function PeopleIcon() {
  return (
    <svg {...glyphProps('people')}>
      <circle cx="9" cy="8" r="3.5" />
      <path d="M3 19a6 6 0 0 1 12 0" />
      <path d="M16.5 5.5a3.5 3.5 0 0 1 0 7M18 19a6 6 0 0 0-2.2-4.6" />
    </svg>
  )
}
