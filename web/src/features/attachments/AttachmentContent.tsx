// Attachments-in-bubbles: a message's attachments rendered inside the chat
// column. One image → single rounded image; several → 2-col grid (max 4 tiles,
// '+N' overlay on the 4th); non-images → filename/size cards. Every
// not-yet-downloaded item shows a download/spinner/retry overlay.

import { useState } from 'react'
import { useLiveQuery } from 'dexie-react-hooks'
import { getDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'
import { cn } from '@/lib/cn'
import { isCalendarInviteAttachment } from '@/mime/calendarInvite'
import { Lightbox } from './Lightbox'
import { formatByteSize } from './formatByteSize'
import { downloadAttachment, isAttachmentDownloadInFlight } from './download'
import { useAttachmentUrl } from './useAttachmentUrl'

const GRID_MAX_TILES = 4

export function AttachmentContent({
  messageId,
  hideCalendarInviteAttachments = false,
}: {
  messageId: string
  /**
   * Set while the bubble's calendar card presents this message: the card is
   * built from the same payload the .ics attachment carries, so its tile is
   * pure duplication (iOS hidingCalendarInviteAttachments).
   */
  hideCalendarInviteAttachments?: boolean
}) {
  const rows = useLiveQuery(
    () => getDB().attachments.where('messageId').equals(messageId).toArray(),
    [messageId],
  )
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null)

  if (rows === undefined) return null
  const attachments = hideCalendarInviteAttachments
    ? rows.filter((row) => !isCalendarInviteAttachment(row.mimeType, row.filename))
    : rows
  if (attachments.length === 0) return null

  const images = attachments.filter((a) => a.mimeType.startsWith('image/'))
  const files = attachments.filter((a) => !a.mimeType.startsWith('image/'))

  return (
    <div className="flex w-full max-w-[280px] flex-col gap-1.5">
      {images.length === 1 && images[0] !== undefined && (
        <ImageAttachment attachment={images[0]} onOpen={() => setLightboxIndex(0)} />
      )}

      {images.length > 1 && (
        <div className="grid grid-cols-2 gap-1">
          {images.slice(0, GRID_MAX_TILES).map((image, i) => {
            const isOverflowTile = i === GRID_MAX_TILES - 1 && images.length > GRID_MAX_TILES
            return (
              <ImageAttachment
                key={image.id}
                attachment={image}
                square
                overflowCount={isOverflowTile ? images.length - (GRID_MAX_TILES - 1) : 0}
                onOpen={() => setLightboxIndex(i)}
              />
            )
          })}
        </div>
      )}

      {files.map((file) => (
        <FileCard key={file.id} attachment={file} />
      ))}

      {lightboxIndex !== null && (
        <Lightbox
          images={images}
          initialIndex={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
        />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

function ImageAttachment({
  attachment,
  onOpen,
  square = false,
  overflowCount = 0,
}: {
  attachment: AttachmentRow
  onOpen: () => void
  square?: boolean
  overflowCount?: number
}) {
  const url = useAttachmentUrl(attachment.state === 'downloaded' ? attachment.id : null)
  const name = attachment.filename.trim().length > 0 ? attachment.filename : 'Image'
  const aspectRatio =
    !square && attachment.width > 0 && attachment.height > 0
      ? `${attachment.width} / ${attachment.height}`
      : undefined

  if (url === null) {
    return (
      <div
        className={cn(
          'bg-bg-elev relative flex items-center justify-center overflow-hidden rounded-xl',
          square ? 'aspect-square w-full' : 'h-40 w-full max-w-[280px]',
        )}
        style={aspectRatio !== undefined ? { aspectRatio, height: 'auto' } : undefined}
      >
        <DownloadOverlay attachment={attachment} />
        {overflowCount > 0 && (
          <span className="pointer-events-none absolute right-1.5 top-1.5 rounded-full bg-black/50 px-2 py-0.5 text-xs font-semibold text-white">
            +{overflowCount}
          </span>
        )}
      </div>
    )
  }

  return (
    <button
      type="button"
      onClick={onOpen}
      aria-label={`View ${name}`}
      className={cn(
        'relative block overflow-hidden rounded-xl active:opacity-80',
        square ? 'aspect-square w-full' : 'w-full max-w-[280px]',
      )}
    >
      <img
        src={url}
        alt={name}
        loading="lazy"
        className="h-full w-full object-cover"
        style={aspectRatio !== undefined ? { aspectRatio } : undefined}
      />
      {overflowCount > 0 && (
        <span className="absolute inset-0 flex items-center justify-center bg-black/50 text-lg font-semibold text-white">
          +{overflowCount}
        </span>
      )}
    </button>
  )
}

// ---------------------------------------------------------------------------
// Non-image files (PDFs etc.)
// ---------------------------------------------------------------------------

function FileCard({ attachment }: { attachment: AttachmentRow }) {
  const url = useAttachmentUrl(attachment.state === 'downloaded' ? attachment.id : null)
  const name = attachment.filename.trim().length > 0 ? attachment.filename : 'Attachment'

  return (
    <div className="border-border bg-bg-elev flex w-full items-center gap-2.5 rounded-xl border px-3 py-2">
      <FileIcon />
      <div className="min-w-0 flex-1">
        <p className="text-fg truncate text-sm font-medium">{name}</p>
        <p className="text-fg-muted text-xs">{formatByteSize(attachment.byteSize)}</p>
      </div>
      {url !== null ? (
        <a
          href={url}
          download={name}
          aria-label={`Download ${name}`}
          className="text-accent hover:bg-bg flex size-9 shrink-0 items-center justify-center rounded-full active:opacity-70"
        >
          <ArrowDownIcon />
        </a>
      ) : (
        <DownloadOverlay attachment={attachment} compact />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Download overlay (remote → cloud button, downloading → spinner, failed → retry)
// ---------------------------------------------------------------------------

function DownloadOverlay({
  attachment,
  compact = false,
}: {
  attachment: AttachmentRow
  compact?: boolean
}) {
  const [busy, setBusy] = useState(() => isAttachmentDownloadInFlight(attachment.id))
  const failed = attachment.state === 'failed'
  const name = attachment.filename.trim().length > 0 ? attachment.filename : 'attachment'

  const start = async (): Promise<void> => {
    setBusy(true)
    try {
      await downloadAttachment(getDB(), attachment)
    } finally {
      setBusy(false)
    }
  }

  const sizeClass = compact ? 'size-9' : 'size-11'

  if (busy) {
    return (
      <span
        role="status"
        aria-label={`Downloading ${name}`}
        className={cn('text-accent flex items-center justify-center', sizeClass)}
      >
        <SpinnerIcon />
      </span>
    )
  }

  return (
    <button
      type="button"
      aria-label={failed ? `Retry download of ${name}` : `Download ${name}`}
      onClick={() => void start()}
      className={cn(
        'text-accent hover:bg-bg flex shrink-0 items-center justify-center rounded-full active:opacity-70',
        sizeClass,
        failed && 'text-danger',
      )}
    >
      {failed ? <RetryIcon /> : <CloudDownloadIcon />}
    </button>
  )
}

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

function FileIcon() {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden
      className="text-fg-muted shrink-0"
    >
      <path d="M6 3h8l4 4v14H6V3z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
      <path d="M14 3v4h4" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  )
}

function CloudDownloadIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 22 22" fill="none" aria-hidden>
      <path
        d="M6 16a4 4 0 01-.6-7.96 5.5 5.5 0 0110.7 1.2A3.5 3.5 0 0116 16H6z"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinejoin="round"
      />
      <path
        d="M11 9v6m0 0l-2.3-2.3M11 15l2.3-2.3"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function ArrowDownIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden>
      <path
        d="M9 3v9m0 0L5.5 8.5M9 12l3.5-3.5M3.5 15h11"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function RetryIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden>
      <path
        d="M16 10a6 6 0 11-1.76-4.24M16 3v3h-3"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function SpinnerIcon() {
  return (
    <svg
      width="20"
      height="20"
      viewBox="0 0 20 20"
      fill="none"
      aria-hidden
      className="animate-spin motion-reduce:animate-none"
    >
      <circle cx="10" cy="10" r="7" stroke="currentColor" strokeWidth="2" opacity="0.25" />
      <path d="M10 3a7 7 0 017 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    </svg>
  )
}
