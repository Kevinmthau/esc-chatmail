// Paperclip button + the hidden file input it drives (port of
// AttachmentPicker.swift's paperclip control; the web platform's single
// `<input type="file">` covers both of iOS's photo and document pickers).

import { useRef } from 'react'
import { IconButton } from '@/components/ui/IconButton'
import { ATTACHMENT_ACCEPT } from './useAttachmentPicker'

export interface AttachmentPickerButtonProps {
  onFiles: (files: readonly File[]) => void
  disabled?: boolean
  className?: string
}

export function AttachmentPickerButton({
  onFiles,
  disabled = false,
  className,
}: AttachmentPickerButtonProps) {
  const inputRef = useRef<HTMLInputElement>(null)

  return (
    <>
      <IconButton
        aria-label="Add attachment"
        disabled={disabled}
        onClick={() => inputRef.current?.click()}
        {...(className !== undefined ? { className } : {})}
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
      <input
        ref={inputRef}
        type="file"
        multiple
        accept={ATTACHMENT_ACCEPT}
        aria-label="Attach files"
        className="hidden"
        onChange={(event) => {
          const files = [...(event.target.files ?? [])]
          // Reset first: picking the same file twice in a row fires no change
          // event otherwise, so the second attempt would look like a dead
          // button.
          event.target.value = ''
          if (files.length > 0) onFiles(files)
        }}
      />
    </>
  )
}
