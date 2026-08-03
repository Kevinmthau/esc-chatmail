// Sandboxed email viewer host. Renders /email-frame.html in an opaque-origin
// iframe and posts the (already sanitized) document + cid Blobs into it.
// Object URLs are minted inside the frame — parent-created ones would be
// unfetchable across the opaque-origin boundary.

import { useEffect, useRef, useState } from 'react'
import { EMAIL_NATURAL_WIDTH, PREVIEW_HEIGHT_DEFAULT } from '@/lib/constants'
import type { EmailRenderMode } from './sanitizeEmailHtml'

interface EmailFrameProps {
  /** Sanitized full-document HTML (sanitizeEmailHtml output). */
  html: string
  /** Blob per Content-ID for inline images; structured-cloned into the frame. */
  cidBlobs: Record<string, Blob>
  mode: EmailRenderMode
}

export function EmailFrame({ html, cidBlobs, mode }: EmailFrameProps) {
  const frameRef = useRef<HTMLIFrameElement>(null)
  const wrapperRef = useRef<HTMLDivElement>(null)
  // Counter (not boolean) so a frame reload re-posts the current payload.
  const [loadCount, setLoadCount] = useState(0)
  const [cardWidth, setCardWidth] = useState(EMAIL_NATURAL_WIDTH)

  useEffect(() => {
    if (loadCount === 0) return
    // The frame trusts the first window that posts a render message; the
    // sandboxed frame's origin is opaque, so targetOrigin must be '*'.
    frameRef.current?.contentWindow?.postMessage({ type: 'render', html, cidBlobs }, '*')
  }, [loadCount, html, cidBlobs])

  useEffect(() => {
    if (mode !== 'preview') return
    const wrapper = wrapperRef.current
    if (wrapper === null || typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver((entries) => {
      const width = entries[0]?.contentRect.width
      if (width !== undefined && width > 0) setCardWidth(width)
    })
    observer.observe(wrapper)
    return () => observer.disconnect()
  }, [mode])

  const scale = Math.max(cardWidth, 1) / EMAIL_NATURAL_WIDTH

  const iframe = (
    <iframe
      ref={frameRef}
      src="/email-frame.html"
      sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox"
      referrerPolicy="no-referrer"
      title="Email content"
      onLoad={() => setLoadCount((count) => count + 1)}
      className={mode === 'full' ? 'h-full w-full border-0' : 'border-0'}
      style={
        mode === 'preview'
          ? {
              width: EMAIL_NATURAL_WIDTH,
              height: PREVIEW_HEIGHT_DEFAULT / scale,
              transform: `scale(${scale})`,
              transformOrigin: 'top left',
              pointerEvents: 'none',
            }
          : undefined
      }
    />
  )

  if (mode === 'full') return iframe

  return (
    <div
      ref={wrapperRef}
      className="pointer-events-none overflow-hidden"
      style={{ height: PREVIEW_HEIGHT_DEFAULT }}
    >
      {iframe}
    </div>
  )
}
