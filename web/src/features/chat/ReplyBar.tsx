// Bottom compose bar (port of ChatReplyBar): glass chrome, growing textarea
// (1–4 lines), attachment picker + staged-attachment strip, and the circular
// accent send button. Enter sends on desktop (Shift+Enter for a newline); the
// draft and staged files clear immediately on send — the optimistic message
// row appears via liveQuery — and are restored if the send fails, together
// with an alert line naming the reason (e.g. a recipient address the MIME
// builder refused), cleared as soon as the user types again.
//
// A send that fails AFTER the optimistic insert while carrying attachments
// leaves the message in the chat as a retryable failed bubble
// (SendFailedError.keptFailedMessage); restoring the draft or the files here
// as well would duplicate the message the moment that retry succeeds.

import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
  type KeyboardEvent,
} from 'react'
import { GlassBar } from '@/components/ui/GlassBar'
import { sendMessage } from '@/data/actions'
import { AttachmentPickerButton } from '@/features/compose/AttachmentPickerButton'
import { AttachmentStrip } from '@/features/compose/AttachmentStrip'
import { useAttachmentPicker } from '@/features/compose/useAttachmentPicker'
// Pure copy helpers (no db/broker plumbing), so they are imported straight
// from the outbox rather than through the data-actions facade.
import { SendFailedError, sendFailureMessage } from '@/outbox/send'
import { restoreDraftIfEmpty, useDraft } from './useDraft'

/** ~4 lines of 15px text plus padding. */
const MAX_TEXTAREA_HEIGHT_PX = 96

export interface ReplyBarApi {
  focus: () => void
}

export interface ReplyBarProps {
  conversationId: string
  /** Called right after a send is initiated (imperative scroll-to-bottom). */
  onSent: () => void
}

function isCoarsePointer(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia('(pointer: coarse)').matches
}

export const ReplyBar = forwardRef<ReplyBarApi, ReplyBarProps>(function ReplyBar(
  { conversationId, onSent },
  ref,
) {
  const [draft, setDraft] = useDraft(conversationId)
  const [sending, setSending] = useState(false)
  const [sendError, setSendError] = useState<string | null>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const picker = useAttachmentPicker()

  useImperativeHandle(ref, () => ({
    focus: () => textareaRef.current?.focus(),
  }))

  // Height fallback for browsers without field-sizing:content.
  useEffect(() => {
    const textarea = textareaRef.current
    if (textarea === null || 'fieldSizing' in textarea.style) return
    textarea.style.height = 'auto'
    textarea.style.height = `${Math.min(textarea.scrollHeight, MAX_TEXTAREA_HEIGHT_PX)}px`
  }, [draft])

  const attachments = picker.attachments
  const canSend = (draft.trim().length > 0 || attachments.length > 0) && !sending && !picker.busy

  const send = async (): Promise<void> => {
    const body = draft.trim()
    if ((body.length === 0 && attachments.length === 0) || sending) return
    const staged = attachments
    setDraft('')
    picker.clear()
    setSending(true)
    setSendError(null)
    onSent()
    try {
      await sendMessage({
        conversationId,
        body,
        ...(staged.length > 0 ? { attachments: staged } : {}),
      })
    } catch (error) {
      // Failed sends roll back the optimistic row; give the text and files
      // back — the text via the shared draft store so it reaches whichever
      // ReplyBar instance is mounted now, and only while the draft is still
      // empty so a late failure never overwrites newer typing. The reason is
      // shown above the bar: a rejected recipient address must not fail
      // silently.
      //
      // Unless the failure KEPT the message as a retryable bubble — then the
      // composer must stay empty; the bubble owns the retry.
      if (!(error instanceof SendFailedError && error.keptFailedMessage)) {
        restoreDraftIfEmpty(conversationId, body)
        if (staged.length > 0) picker.restore(staged)
      }
      setSendError(sendFailureMessage(error))
    } finally {
      setSending(false)
    }
  }

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>): void => {
    if (event.key === 'Enter' && !event.shiftKey && !isCoarsePointer()) {
      event.preventDefault()
      void send()
    }
  }

  return (
    <GlassBar className="shrink-0">
      {sendError !== null && (
        <p role="alert" className="px-3 pt-2 text-sm text-danger">
          {sendError}
        </p>
      )}
      {picker.skippedMessage !== null && (
        <p role="alert" className="px-3 pt-2 text-sm text-danger">
          {picker.skippedMessage}
        </p>
      )}
      <AttachmentStrip attachments={attachments} onRemove={picker.remove} disabled={sending} />
      <div className="flex items-end gap-2 px-3 py-2">
        <AttachmentPickerButton
          onFiles={(files) => void picker.addFiles(files)}
          disabled={sending || picker.busy}
          className="size-9 shrink-0"
        />

        <textarea
          ref={textareaRef}
          rows={1}
          value={draft}
          placeholder="Message"
          aria-label="Message"
          onChange={(event) => {
            setDraft(event.target.value)
            if (sendError !== null) setSendError(null)
            if (picker.skippedMessage !== null) picker.dismissSkipped()
          }}
          onKeyDown={onKeyDown}
          className="rounded-bubble bg-bg-elev text-fg placeholder:text-fg-muted focus-visible:outline-accent max-h-24 min-w-0 flex-1 resize-none px-3 py-2 text-[15px] leading-snug outline-none focus-visible:outline-2 [field-sizing:content]"
        />

        <button
          type="button"
          aria-label="Send"
          disabled={!canSend}
          onClick={() => void send()}
          className="bg-accent flex size-9 shrink-0 items-center justify-center rounded-full text-white active:opacity-70 disabled:opacity-40"
        >
          {sending ? (
            <svg
              width="18"
              height="18"
              viewBox="0 0 18 18"
              fill="none"
              aria-hidden
              className="animate-spin motion-reduce:animate-none"
            >
              <circle cx="9" cy="9" r="6.5" stroke="currentColor" strokeWidth="2" opacity="0.3" />
              <path
                d="M9 2.5a6.5 6.5 0 016.5 6.5"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
              />
            </svg>
          ) : (
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden>
              <path
                d="M9 14.5v-11m0 0L4.5 8M9 3.5L13.5 8"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          )}
        </button>
      </div>
    </GlassBar>
  )
})
