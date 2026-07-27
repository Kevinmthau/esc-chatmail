// Full email reader: bottom sheet on mobile, centered dialog on desktop.
// HTML bodies render in a full-mode EmailFrame; plain-text-only messages
// render as linkified selectable text (textContent-based splitting — the raw
// body never touches innerHTML).

import { useNavigate } from '@tanstack/react-router'
import { useLiveQuery } from 'dexie-react-hooks'
import type { ReactNode } from 'react'
import { IconButton } from '@/components/ui/IconButton'
import { Modal } from '@/components/ui/Modal'
import { Skeleton } from '@/components/ui/Skeleton'
import { getDB } from '@/db/schema'
import { EmailFrame } from './EmailFrame'
import { useEmailHtml } from './useEmailHtml'

interface ReaderDialogProps {
  /** Message to show; undefined keeps the dialog closed. */
  messageId: string | undefined
}

export function ReaderDialog({ messageId }: ReaderDialogProps) {
  const navigate = useNavigate({ from: '/chats/$conversationId' })
  const close = () => void navigate({ to: '.', search: (prev) => ({ ...prev, reader: undefined }) })

  return (
    <Modal
      open={messageId !== undefined}
      onClose={close}
      variant="sheet"
      ariaLabel="Email reader"
      className="h-[85dvh] w-full max-w-2xl"
    >
      {messageId !== undefined ? <ReaderContent messageId={messageId} onClose={close} /> : null}
    </Modal>
  )
}

function ReaderContent({ messageId, onClose }: { messageId: string; onClose: () => void }) {
  const message = useLiveQuery(() => getDB().messages.get(messageId), [messageId])
  const email = useEmailHtml(messageId, 'full')

  return (
    <div className="flex h-[85dvh] max-h-full flex-col">
      <header className="border-border flex items-start gap-3 border-b p-4">
        <div className="min-w-0 flex-1">
          {message === undefined ? (
            <Skeleton className="h-5 w-2/3" />
          ) : (
            <>
              <h2 className="text-fg truncate text-base font-semibold">
                {message.subject.trim().length > 0 ? message.subject : '(no subject)'}
              </h2>
              <p className="text-fg-muted truncate text-sm">
                {message.senderName.trim().length > 0
                  ? `${message.senderName} <${message.senderEmail}>`
                  : message.senderEmail}
              </p>
              <p className="text-fg-muted text-xs">
                {new Date(message.internalDate).toLocaleString(undefined, {
                  dateStyle: 'full',
                  timeStyle: 'short',
                })}
              </p>
            </>
          )}
        </div>
        <IconButton aria-label="Close reader" onClick={onClose}>
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

      <div className="min-h-0 flex-1 overflow-hidden">
        {message === undefined ? (
          <div className="space-y-3 p-4">
            <Skeleton className="h-4 w-full" />
            <Skeleton className="h-4 w-5/6" />
            <Skeleton className="h-4 w-2/3" />
          </div>
        ) : message.hasHtmlBody === 1 ? (
          <HtmlBody email={email} />
        ) : (
          <div className="h-full overflow-y-auto">
            <LinkifiedText text={message.bodyText} />
          </div>
        )}
      </div>
    </div>
  )
}

function HtmlBody({ email }: { email: ReturnType<typeof useEmailHtml> }) {
  if (email.status === 'loading') {
    return (
      <div className="space-y-3 p-4">
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-40 w-full" />
        <Skeleton className="h-4 w-3/4" />
      </div>
    )
  }

  if (email.status === 'failed' || email.html === undefined) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 p-6">
        <p className="text-fg-muted text-sm">This email could not be displayed.</p>
        <button
          type="button"
          onClick={email.retry}
          className="bg-accent rounded-chip px-4 py-2 text-sm font-medium text-white active:opacity-70"
        >
          Retry
        </button>
      </div>
    )
  }

  return <EmailFrame html={email.html} cidBlobs={email.cidBlobs ?? {}} mode="full" />
}

// Simple, safe URL linkification: the text is split around URL matches and
// rendered as React text nodes + anchors. Only http(s) matches become links.
const URL_PATTERN = /https?:\/\/[^\s<>"')\]]+/g

export function LinkifiedText({ text }: { text: string }) {
  const nodes: ReactNode[] = []
  const pattern = new RegExp(URL_PATTERN.source, URL_PATTERN.flags)
  let lastIndex = 0
  let match: RegExpExecArray | null
  while ((match = pattern.exec(text)) !== null) {
    if (match.index > lastIndex) nodes.push(text.slice(lastIndex, match.index))
    const url = match[0]
    nodes.push(
      <a
        key={`${match.index}-${url}`}
        href={url}
        target="_blank"
        rel="noopener noreferrer"
        className="text-accent underline"
      >
        {url}
      </a>,
    )
    lastIndex = match.index + url.length
  }
  if (lastIndex < text.length) nodes.push(text.slice(lastIndex))

  return (
    <p className="text-fg select-text p-4 text-[15px] leading-relaxed whitespace-pre-wrap">
      {nodes}
    </p>
  )
}
