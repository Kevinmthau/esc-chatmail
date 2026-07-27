import { useNavigate } from '@tanstack/react-router'
import { useState } from 'react'
import { IconButton } from '@/components/ui/IconButton'
import { Modal } from '@/components/ui/Modal'
import { sendMessage } from '@/data/actions'
import { setDraft } from '@/features/chat/useDraft'
// Pure copy helper (no db/broker plumbing), so it is imported straight from
// the outbox rather than through the data-actions facade.
import { sendFailureMessage } from '@/outbox/send'
import { AliasPicker } from './AliasPicker'
import { GrowingTextarea } from './GrowingTextarea'
import { RecipientField } from './RecipientField'
import { validRecipientEmails, type RecipientChipData } from './recipients'
import { useRecipientDedup } from './useRecipientDedup'

/**
 * New-message dialog, iMessage style (port of iOS ComposeView newMessage mode):
 * centered "New Message" header, To: chips + autocomplete, dedup-to-existing-
 * chat banner, optional From: alias picker, growing body input + circular send.
 *
 * Mounted from chats.tsx as `{search.compose && <ComposeDialog onClose={...} />}`.
 */
export function ComposeDialog({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate()
  const [chips, setChips] = useState<RecipientChipData[]>([])
  const [body, setBody] = useState('')
  const [fromAlias, setFromAlias] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const [sendError, setSendError] = useState<string | null>(null)
  const existingChat = useRecipientDedup(chips)

  const recipients = validRecipientEmails(chips)
  const canSend = !sending && recipients.length > 0 && body.trim() !== ''

  const handleSend = async (): Promise<void> => {
    if (!canSend) return
    setSending(true)
    setSendError(null)
    try {
      const result = await sendMessage({
        to: recipients,
        body: body.trim(),
        ...(fromAlias !== null ? { fromAlias } : {}),
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

  return (
    <Modal
      open
      onClose={onClose}
      variant="sheet"
      ariaLabel="New message"
      className="w-full md:w-full md:max-w-lg"
    >
      <div className="flex h-[70dvh] flex-col md:h-[560px]">
        <header className="relative flex h-14 shrink-0 items-center justify-center border-b border-border">
          <h2 className="text-base font-semibold">New Message</h2>
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

        <div className="min-h-0 flex-1" />

        {sendError !== null && (
          <p role="alert" className="px-4 pb-2 text-sm text-danger">
            {sendError}
          </p>
        )}

        <footer className="flex shrink-0 items-end gap-2 border-t border-border p-3">
          <GrowingTextarea
            value={body}
            onChange={setBody}
            onSubmit={() => void handleSend()}
            disabled={sending}
          />
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
