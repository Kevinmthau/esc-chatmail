// Full-screen image viewer for a message's image attachments: centered Modal,
// prev/next arrows + ArrowLeft/ArrowRight keys, download anchor.

import { useCallback, useEffect, useState } from 'react'
import { IconButton } from '@/components/ui/IconButton'
import { Modal } from '@/components/ui/Modal'
import type { AttachmentRow } from '@/db/types'
import { useAttachmentUrl } from './useAttachmentUrl'

interface LightboxProps {
  images: readonly AttachmentRow[]
  initialIndex: number
  onClose: () => void
}

export function Lightbox({ images, initialIndex, onClose }: LightboxProps) {
  const [index, setIndex] = useState(() =>
    Math.min(Math.max(initialIndex, 0), Math.max(images.length - 1, 0)),
  )
  const current = images[index] ?? null
  const url = useAttachmentUrl(
    current !== null && current.state === 'downloaded' ? current.id : null,
  )

  const showPrev = useCallback(() => {
    setIndex((i) => (i > 0 ? i - 1 : i))
  }, [])
  const showNext = useCallback(() => {
    setIndex((i) => (i < images.length - 1 ? i + 1 : i))
  }, [images.length])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'ArrowLeft') showPrev()
      else if (event.key === 'ArrowRight') showNext()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
    }
  }, [showPrev, showNext])

  const filename = current?.filename ?? ''
  const displayName = filename.trim().length > 0 ? filename : 'Image'

  return (
    <Modal open onClose={onClose} ariaLabel="Image viewer" className="w-[min(92vw,56rem)]">
      <div className="flex max-h-[85dvh] flex-col">
        <header className="border-border flex shrink-0 items-center gap-1 border-b px-2 py-1">
          <p className="text-fg min-w-0 flex-1 truncate px-2 text-sm font-medium">
            <span>{displayName}</span>
            {images.length > 1 && (
              <span className="text-fg-muted">{` · ${index + 1} of ${images.length}`}</span>
            )}
          </p>
          {url !== null && (
            <a
              href={url}
              download={displayName}
              aria-label={`Download ${displayName}`}
              className="text-accent hover:bg-bg-elev flex size-11 items-center justify-center rounded-full active:opacity-70"
            >
              <DownloadIcon />
            </a>
          )}
          <IconButton aria-label="Close image viewer" onClick={onClose}>
            <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden>
              <path
                d="M5 5l10 10M15 5L5 15"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
              />
            </svg>
          </IconButton>
        </header>

        <div className="relative flex min-h-64 flex-1 items-center justify-center overflow-hidden p-2">
          {url !== null ? (
            <img
              src={url}
              alt={displayName}
              className="max-h-[70dvh] max-w-full rounded-lg object-contain"
            />
          ) : (
            <p className="text-fg-muted p-10 text-sm">Image not downloaded</p>
          )}

          {images.length > 1 && (
            <>
              <IconButton
                aria-label="Previous image"
                onClick={showPrev}
                disabled={index === 0}
                className="bg-glass absolute left-2 top-1/2 -translate-y-1/2 backdrop-blur"
              >
                <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden>
                  <path
                    d="M12.5 4L6.5 10l6 6"
                    stroke="currentColor"
                    strokeWidth="1.8"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </IconButton>
              <IconButton
                aria-label="Next image"
                onClick={showNext}
                disabled={index === images.length - 1}
                className="bg-glass absolute right-2 top-1/2 -translate-y-1/2 backdrop-blur"
              >
                <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden>
                  <path
                    d="M7.5 4l6 6-6 6"
                    stroke="currentColor"
                    strokeWidth="1.8"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </IconButton>
            </>
          )}
        </div>
      </div>
    </Modal>
  )
}

function DownloadIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden>
      <path
        d="M10 3v9m0 0l-3.5-3.5M10 12l3.5-3.5M4 16h12"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}
