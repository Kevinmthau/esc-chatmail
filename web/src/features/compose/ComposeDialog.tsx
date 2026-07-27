import { useNavigate } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { IconButton } from '@/components/ui/IconButton'
import { Modal } from '@/components/ui/Modal'
import { sendMessage } from '@/data/actions'
import { getDB } from '@/db/schema'
import { setDraft } from '@/features/chat/useDraft'
// Pure copy helpers (no db/broker plumbing), so they are imported straight
// from the outbox rather than through the data-actions facade.
import {
  buildForwardHtmlBody,
  extractUserNote,
  forwardedBlockUnedited,
} from '@/outbox/forwardMetadata'
import { sendFailureMessage, type ForwardSendPayload } from '@/outbox/send'
import { AliasPicker } from './AliasPicker'
import { buildForwardDraft, skippedAttachmentWarning, type ForwardDraft } from './forwardSource'
import { GrowingTextarea } from './GrowingTextarea'
import { RecipientField } from './RecipientField'
import { validRecipientEmails, type RecipientChipData } from './recipients'
import { useRecipientDedup } from './useRecipientDedup'

/** Stable identity so the dedup effect does not re-run every forward render. */
const NO_CHIPS: RecipientChipData[] = []

/**
 * New-message dialog, iMessage style (port of iOS ComposeView newMessage
 * mode): centered "New Message" header, To: chips + autocomplete, dedup-to-
 * existing-chat banner, optional From: alias picker, growing body input +
 * circular send.
 *
 * With `forwardMessageId` it opens in FORWARD mode instead (ComposeView
 * .forward): "Forward" title, an editable Subject row, empty recipients (the
 * To field keeps the autofocus) and a body prefilled with the forwarded-
 * message block, which the user types their note above.
 *
 * Mounted from chats.tsx as `{search.compose && <ComposeDialog onClose={...} />}`.
 */
export function ComposeDialog({
  onClose,
  forwardMessageId,
}: {
  onClose: () => void
  /** Message being forwarded; absent for a plain new message. */
  forwardMessageId?: string
}) {
  const navigate = useNavigate()
  const [chips, setChips] = useState<RecipientChipData[]>([])
  const [body, setBody] = useState('')
  const [subject, setSubject] = useState('')
  const [fromAlias, setFromAlias] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const [sendError, setSendError] = useState<string | null>(null)
  const isForward = forwardMessageId !== undefined
  const [forward, setForward] = useState<ForwardDraft | null>(null)
  const [preparing, setPreparing] = useState(isForward)

  // Dedup deliberately does NOT run in forward mode. Its only affordance is
  // "Open chat", which hands the typed body to that chat's reply bar and drops
  // everything else the forward carries (subject, the forwarded block, the
  // sanitized html alternative) — a silent data loss. iOS composes a fresh
  // message for a forward too. Routing is unaffected: the send pipeline still
  // resolves the participant-set conversation, so a forward to an existing
  // chat's recipients lands in that chat.
  const existingChat = useRecipientDedup(isForward ? NO_CHIPS : chips)

  useEffect(() => {
    if (forwardMessageId === undefined) return
    let cancelled = false
    setPreparing(true)
    void (async () => {
      try {
        const draft = await buildForwardDraft(getDB(), forwardMessageId)
        if (cancelled || draft === null) return
        setForward(draft)
        setSubject(draft.subject)
        setBody(draft.body)
      } catch {
        // Nothing to forward: the dialog stays usable as a plain compose.
      } finally {
        if (!cancelled) setPreparing(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [forwardMessageId])

  const recipients = validRecipientEmails(chips)
  // Forward mode mirrors iOS canSend: the forwarded content IS the message, so
  // an empty note does not block the send — but only once the forwarded draft
  // actually loaded. When the source message is gone the dialog degrades to a
  // plain compose (see the fetch effect), and a plain compose needs a body:
  // without this a stale ?forward= URL could send an empty '(No Subject)'
  // shell the moment a recipient lands.
  const hasContent = isForward
    ? !preparing && (forward !== null || body.trim() !== '')
    : body.trim() !== ''
  const canSend = !sending && recipients.length > 0 && hasContent

  const forwardPayload = (): ForwardSendPayload | undefined => {
    if (!isForward || forward === null) return undefined
    // The html alternative is rebuilt from the pristine draft pieces, so it
    // only ships while the block below the marker is untouched: an edited or
    // deleted block makes the plain text the single honest copy, and most
    // clients render html in preference to it.
    const html =
      forward.sanitizedContentHtml == null || !forwardedBlockUnedited(body, forward.body)
        ? undefined
        : buildForwardHtmlBody({
            userNote: extractUserNote(body),
            header: forward.header,
            sanitizedContentHtml: forward.sanitizedContentHtml,
          })
    return { subject: subject.trim(), ...(html !== undefined ? { htmlBody: html } : {}) }
  }

  const handleSend = async (): Promise<void> => {
    if (!canSend) return
    setSending(true)
    setSendError(null)
    const payload = forwardPayload()
    try {
      const result = await sendMessage({
        to: recipients,
        body: body.trim(),
        ...(fromAlias !== null ? { fromAlias } : {}),
        ...(payload !== undefined ? { forward: payload } : {}),
      })
      onClose()
      await navigate({
        to: '/chats/$conversationId',
        params: { conversationId: result.conversationId },
      })
    } catch (error) {
      // Address rejections name the offending addresses; everything else
      // falls back to the generic line.
      setSendError(sendFailureMessage(error))
      setSending(false)
    }
  }

  const handleOpenExisting = (): void => {
    if (existingChat === null) return
    // Carry the typed body into that chat's reply-bar draft.
    if (body.trim() !== '') setDraft(existingChat.conversationId, body)
    onClose()
    void navigate({
      to: '/chats/$conversationId',
      params: { conversationId: existingChat.conversationId },
    })
  }

  const title = isForward ? 'Forward' : 'New Message'

  return (
    <Modal
      open
      onClose={onClose}
      variant="sheet"
      ariaLabel={title}
      className="w-full md:w-full md:max-w-lg"
    >
      <div className="flex h-[70dvh] flex-col md:h-[560px]">
        <header className="relative flex h-14 shrink-0 items-center justify-center border-b border-border">
          <h2 className="text-base font-semibold">{title}</h2>
          <IconButton
            aria-label="Close"
            onClick={onClose}
            className="absolute right-2 size-8 bg-bg-elev text-fg-muted"
          >
            <svg
              viewBox="0 0 16 16"
              className="size-3.5"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              aria-hidden
            >
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </IconButton>
        </header>

        <AliasPicker value={fromAlias} onChange={setFromAlias} />
        <RecipientField chips={chips} onChipsChange={setChips} disabled={sending} />

        {isForward && (
          <div className="flex items-center gap-2 border-b border-border px-4 py-2">
            <label htmlFor="compose-subject" className="text-sm text-fg-muted">
              Subject:
            </label>
            <input
              id="compose-subject"
              type="text"
              value={subject}
              disabled={sending}
              onChange={(event) => setSubject(event.target.value)}
              className="min-w-0 flex-1 bg-transparent py-1 text-sm text-fg outline-none"
            />
          </div>
        )}

        {existingChat !== null && (
          <div
            role="status"
            className="flex items-center gap-2 border-b border-border bg-bg-elev px-4 py-2 text-sm"
          >
            <span className="min-w-0 flex-1 truncate">
              You already have a chat with {existingChat.displayName || 'this recipient'}
            </span>
            <button
              type="button"
              onClick={handleOpenExisting}
              className="shrink-0 rounded-chip px-2 py-1 font-semibold text-accent hover:bg-accent/10 focus-visible:outline-2 focus-visible:outline-accent"
            >
              Open chat
            </button>
          </div>
        )}

        {isForward && forward !== null && forward.skippedAttachmentCount > 0 && (
          <p role="status" className="px-4 pt-2 text-xs text-warning">
            {skippedAttachmentWarning(forward.skippedAttachmentCount)}
          </p>
        )}

        {isForward ? (
          // The forwarded block is long; it gets the dialog's whole free
          // height instead of the one-line growing input.
          <div className="min-h-0 flex-1 px-4 py-2">
            <textarea
              aria-label="Message body"
              placeholder="Add a message (optional)"
              value={body}
              disabled={sending || preparing}
              onChange={(event) => setBody(event.target.value)}
              className="h-full w-full resize-none bg-transparent text-[15px] text-fg outline-none placeholder:text-fg-muted disabled:opacity-60"
            />
          </div>
        ) : (
          <div className="min-h-0 flex-1" />
        )}

        {sendError !== null && (
          <p role="alert" className="px-4 pb-2 text-sm text-danger">
            {sendError}
          </p>
        )}

        <footer className="flex shrink-0 items-end gap-2 border-t border-border p-3">
          {!isForward && (
            <GrowingTextarea
              value={body}
              onChange={setBody}
              onSubmit={() => void handleSend()}
              disabled={sending}
            />
          )}
          {isForward && <div className="min-w-0 flex-1" />}
          <IconButton
            aria-label="Send"
            disabled={!canSend}
            onClick={() => void handleSend()}
            className="size-8 shrink-0 bg-accent text-white hover:bg-accent hover:opacity-90"
          >
            <svg
              viewBox="0 0 20 20"
              className="size-4"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.2"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden
            >
              <path d="M10 16V4M4.5 9.5L10 4l5.5 5.5" />
            </svg>
          </IconButton>
        </footer>
      </div>
    </Modal>
  )
}
