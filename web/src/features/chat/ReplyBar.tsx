// Bottom compose bar (port of ChatReplyBar): glass chrome, growing textarea
// (1–4 lines), disabled attachment button (outbound attachments are post-MVP),
// and the circular accent send button. Enter sends on desktop (Shift+Enter for
// a newline); the draft clears immediately on send — the optimistic message
// row appears via liveQuery — and is restored if the send fails, together
// with an alert line naming the reason (e.g. a recipient address the MIME
// builder refused), cleared as soon as the user types again.

import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
  type KeyboardEvent,
} from 'react'
import { GlassBar } from '@/components/ui/GlassBar'
import { IconButton } from '@/components/ui/IconButton'
import { sendMessage } from '@/data/actions'
// Pure copy helper (no db/broker plumbing), so it is imported straight from
// the outbox rather than through the data-actions facade.
import { sendFailureMessage } from '@/outbox/send'
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

  const canSend = draft.trim().length > 0 && !sending

  const send = async (): Promise<void> => {
    const body = draft.trim()
    if (body.length === 0 || sending) return
    setDraft('')
    setSending(true)
    setSendError(null)
    onSent()
    try {
      await sendMessage({ conversationId, body })
    } catch (error) {
      // Failed sends roll back the optimistic row; give the text back — via
      // the shared draft store so it reaches whichever ReplyBar instance is
      // mounted now, and only while the draft is still empty so a late failure
      // never overwrites newer typing. The reason is shown above the bar: a
      // rejected recipient address must not fail silently.
      restoreDraftIfEmpty(conversationId, body)
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
      <div className="flex items-end gap-2 px-3 py-2">
        <IconButton
          aria-label="Add attachment"
          title="Coming soon"
          disabled
          className="size-9 shrink-0"
        >
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden>
            <path
              d="M12.5 5.5l-5.8 5.8a2.3 2.3 0 003.2 3.2l6-6a3.8 3.8 0 00-5.4-5.4l-6 6a5.3 5.3 0 007.5 7.5l5-5"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </IconButton>

        <textarea
          ref={textareaRef}
          rows={1}
          value={draft}
          placeholder="Message"
          aria-label="Message"
          onChange={(event) => {
            setDraft(event.target.value)
            if (sendError !== null) setSendError(null)
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
