// Composer-side attachment staging. Port of ComposeAttachmentManager.swift's
// add/remove/clear plus AttachmentPicker.swift's processing loop, hoisted into
// a hook so the reply bar and the compose dialog share one implementation.
//
// Files are downscaled and size-checked off the render path
// (outbox/outboundAttachments.prepareAttachments); anything skipped is
// surfaced as a message rather than silently dropped the way iOS does.

import { useCallback, useState } from 'react'
import {
  prepareAttachments,
  skippedAttachmentMessage,
  type PendingAttachment,
} from '@/outbox/outboundAttachments'

/** File types the picker offers; `<input accept>` is a hint, not a guarantee. */
export const ATTACHMENT_ACCEPT = 'image/*,application/pdf'

export interface AttachmentPicker {
  attachments: PendingAttachment[]
  /** Copy naming files that were skipped (oversize); null when there are none. */
  skippedMessage: string | null
  /** True while picked files are being decoded/downscaled. */
  busy: boolean
  addFiles: (files: readonly File[]) => Promise<void>
  remove: (id: string) => void
  clear: () => void
  /** Puts a previously staged set back (a pre-flight send failure). */
  restore: (attachments: readonly PendingAttachment[]) => void
  dismissSkipped: () => void
}

export function useAttachmentPicker(): AttachmentPicker {
  const [attachments, setAttachments] = useState<PendingAttachment[]>([])
  const [skippedMessage, setSkippedMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const addFiles = useCallback(async (files: readonly File[]): Promise<void> => {
    if (files.length === 0) return
    setBusy(true)
    setSkippedMessage(null)
    try {
      const prepared = await prepareAttachments(files)
      if (prepared.attachments.length > 0) {
        setAttachments((current) => [...current, ...prepared.attachments])
      }
      setSkippedMessage(skippedAttachmentMessage(prepared.skipped))
    } finally {
      setBusy(false)
    }
  }, [])

  const remove = useCallback((id: string): void => {
    setAttachments((current) => current.filter((attachment) => attachment.id !== id))
  }, [])

  const clear = useCallback((): void => {
    setAttachments([])
    setSkippedMessage(null)
  }, [])

  const restore = useCallback((restored: readonly PendingAttachment[]): void => {
    setAttachments([...restored])
  }, [])

  const dismissSkipped = useCallback((): void => {
    setSkippedMessage(null)
  }, [])

  return { attachments, skippedMessage, busy, addFiles, remove, clear, restore, dismissSkipped }
}
