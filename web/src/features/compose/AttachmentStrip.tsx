// Staged-attachment strip above the composer (port of
// AttachmentPreviewStrip.swift / ComposeAttachmentThumbnail.swift): image
// thumbnails, filename+size cards for everything else, each with a remove
// control.

import { useEffect, useState } from 'react'
import { formatByteSize } from '@/features/attachments/formatByteSize'
import type { PendingAttachment } from '@/outbox/outboundAttachments'

export interface AttachmentStripProps {
  attachments: readonly PendingAttachment[]
  onRemove: (id: string) => void
  disabled?: boolean
}

export function AttachmentStrip({ attachments, onRemove, disabled = false }: AttachmentStripProps) {
  if (attachments.length === 0) return null

  return (
    <ul
      aria-label="Attachments"
      className="flex gap-2 overflow-x-auto border-b border-border px-3 py-2"
    >
      {attachments.map((attachment) => (
        <li key={attachment.id} className="relative shrink-0">
          <AttachmentTile attachment={attachment} />
          <button
            type="button"
            aria-label={`Remove ${attachment.filename}`}
            disabled={disabled}
            onClick={() => onRemove(attachment.id)}
            className="absolute -right-1 -top-1 flex size-5 items-center justify-center rounded-full bg-black/70 text-white active:opacity-70 disabled:opacity-40"
          >
            <svg viewBox="0 0 12 12" className="size-2.5" fill="none" aria-hidden>
              <path
                d="M3 3l6 6M9 3l-6 6"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
              />
            </svg>
          </button>
        </li>
      ))}
    </ul>
  )
}

/** Object URL for a staged blob, revoked when the tile unmounts. */
function useBlobUrl(blob: Blob | null): string | null {
  const [url, setUrl] = useState<string | null>(null)

  useEffect(() => {
    if (blob === null) {
      setUrl(null)
      return
    }
    const objectUrl = URL.createObjectURL(blob)
    setUrl(objectUrl)
    return () => {
      URL.revokeObjectURL(objectUrl)
    }
  }, [blob])

  return url
}

function AttachmentTile({ attachment }: { attachment: PendingAttachment }) {
  const isImage = attachment.mimeType.startsWith('image/')
  const url = useBlobUrl(isImage ? attachment.blob : null)

  if (isImage && url !== null) {
    return (
      <img
        src={url}
        alt={attachment.filename}
        className="size-14 rounded-lg object-cover"
        // The blob is local, so there is nothing to lazy-load.
        decoding="async"
      />
    )
  }

  return (
    <div className="flex h-14 w-36 flex-col justify-center rounded-lg border border-border bg-bg-elev px-2">
      <span className="truncate text-xs font-medium text-fg">{attachment.filename}</span>
      <span className="text-[11px] text-fg-muted">{formatByteSize(attachment.byteSize)}</span>
    </div>
  )
}
