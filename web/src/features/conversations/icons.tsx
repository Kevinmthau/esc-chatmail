// Inline SVG glyphs for the conversation list (no icon library by design).
// Every icon is decorative (aria-hidden); buttons carry their own aria-labels.

interface IconProps {
  className?: string
}

function iconProps(className: string | undefined, name: string) {
  return {
    viewBox: '0 0 24 24',
    fill: 'none' as const,
    stroke: 'currentColor',
    strokeWidth: 2,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    'aria-hidden': true,
    'data-icon': name,
    className,
  }
}

export function PinIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'pin')} fill="currentColor" strokeWidth={0}>
      <path d="M14.6 2.6a1 1 0 0 0-1.4 0L9.9 5.9a5.5 5.5 0 0 0-4.2 1.6 1 1 0 0 0 0 1.4l3.2 3.2-4.6 4.6a1 1 0 1 0 1.4 1.4l4.6-4.6 3.2 3.2a1 1 0 0 0 1.4 0 5.5 5.5 0 0 0 1.6-4.2l3.3-3.3a1 1 0 0 0 0-1.4z" />
    </svg>
  )
}

export function ArchiveIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'archive')}>
      <rect x="3" y="4" width="18" height="5" rx="1" />
      <path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9" />
      <path d="M10 13h4" />
    </svg>
  )
}

export function MarkReadIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'mark-read')}>
      <circle cx="12" cy="12" r="9" />
      <path d="m8.5 12 2.5 2.5 4.5-4.5" />
    </svg>
  )
}

export function MarkUnreadIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'mark-unread')}>
      <circle cx="12" cy="12" r="9" />
      <circle cx="12" cy="12" r="3.5" fill="currentColor" strokeWidth={0} />
    </svg>
  )
}

export function RefreshIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'refresh')}>
      <path d="M20 11a8 8 0 1 0-1.5 5.5" />
      <path d="M20 5v6h-6" />
    </svg>
  )
}

export function ComposeIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'compose')}>
      <path d="M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5" />
      <path d="M17.5 3.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z" />
    </svg>
  )
}

export function GearIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'gear')}>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.9 2.9l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.9-2.9l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.9-2.9l.1.1a1.7 1.7 0 0 0 1.9.3h.1a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.9 2.9l-.1.1a1.7 1.7 0 0 0-.3 1.9v.1a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" />
    </svg>
  )
}

export function ChevronDownIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'chevron-down')}>
      <path d="m6 9 6 6 6-6" />
    </svg>
  )
}

export function EnvelopeIcon({ className }: IconProps) {
  return (
    <svg {...iconProps(className, 'envelope')}>
      <rect x="3" y="5" width="18" height="14" rx="2" />
      <path d="m3 7 9 6 9-6" />
    </svg>
  )
}
