// Reply bar send flow: Enter sends via data/actions.sendMessage, the draft
// clears immediately, and failed sends restore the draft — visibly on the
// instance mounted NOW, and never over newer typing.

import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { sendMessage } from '@/data/actions'
import { prepareAttachments } from '@/outbox/outboundAttachments'
import { GENERIC_SEND_ERROR, SendFailedError } from '@/outbox/send'
import { ReplyBar } from './ReplyBar'
import { clearDraftsForTests } from './useDraft'

vi.mock('@/data/actions', () => ({
  sendMessage: vi.fn(),
}))

// Passthrough by default; individual tests swap in a hanging implementation
// to hold the picker in its busy state.
vi.mock('@/outbox/outboundAttachments', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/outbox/outboundAttachments')>()
  return { ...actual, prepareAttachments: vi.fn(actual.prepareAttachments) }
})

const mockedSend = vi.mocked(sendMessage)

beforeEach(() => {
  clearDraftsForTests()
  mockedSend.mockResolvedValue({ messageId: 'g1', conversationId: 'c1' })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function textarea(): HTMLTextAreaElement {
  return screen.getByRole('textbox', { name: 'Message' })
}

function sendButton(): HTMLButtonElement {
  return screen.getByRole('button', { name: 'Send' })
}

describe('ReplyBar', () => {
  it('disables the send button while the draft is empty', async () => {
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
    expect(sendButton().disabled).toBe(true)
    await userEvent.type(textarea(), 'hi')
    expect(sendButton().disabled).toBe(false)
  })

  it('sends on Enter, clears the draft, and notifies onSent', async () => {
    const onSent = vi.fn()
    render(<ReplyBar conversationId="c1" onSent={onSent} />)

    await userEvent.type(textarea(), 'hello there{Enter}')

    expect(mockedSend).toHaveBeenCalledWith({ conversationId: 'c1', body: 'hello there' })
    expect(onSent).toHaveBeenCalledTimes(1)
    expect(textarea().value).toBe('')
  })

  it('inserts a newline on Shift+Enter without sending', async () => {
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)

    await userEvent.type(textarea(), 'line one{Shift>}{Enter}{/Shift}line two')

    expect(mockedSend).not.toHaveBeenCalled()
    expect(textarea().value).toBe('line one\nline two')
  })

  it('sends via the send button and trims the body', async () => {
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
    await userEvent.type(textarea(), '  spaced out  ')
    await userEvent.click(sendButton())
    expect(mockedSend).toHaveBeenCalledWith({ conversationId: 'c1', body: 'spaced out' })
  })

  it('does not send an empty draft on Enter', async () => {
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
    await userEvent.type(textarea(), '{Enter}')
    expect(mockedSend).not.toHaveBeenCalled()
  })

  it('restores the draft when the send fails', async () => {
    mockedSend.mockRejectedValueOnce(new Error('offline'))
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)

    await userEvent.type(textarea(), 'try again{Enter}')

    await waitFor(() => {
      expect(textarea().value).toBe('try again')
    })
  })

  it('failed-send restore reaches the reply bar mounted NOW (left and returned mid-flight)', async () => {
    let rejectSend!: (error: Error) => void
    mockedSend.mockImplementationOnce(
      () =>
        new Promise<never>((_, reject) => {
          rejectSend = reject
        }),
    )
    const first = render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
    await userEvent.type(textarea(), 'try again{Enter}')
    first.unmount() // navigate to another chat while the send is in flight...

    render(<ReplyBar conversationId="c1" onSent={() => undefined} />) // ...and back
    expect(textarea().value).toBe('')

    await act(async () => {
      rejectSend(new Error('offline'))
      await Promise.resolve()
    })
    // The failure must surface in the CURRENT instance, not a stale one.
    expect(textarea().value).toBe('try again')
  })

  it('a late send failure does not clobber newer typing', async () => {
    let rejectSend!: (error: Error) => void
    mockedSend.mockImplementationOnce(
      () =>
        new Promise<never>((_, reject) => {
          rejectSend = reject
        }),
    )
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)

    await userEvent.type(textarea(), 'first message{Enter}')
    await userEvent.type(textarea(), 'newer draft') // typed while the send is in flight

    await act(async () => {
      rejectSend(new Error('offline'))
      await Promise.resolve()
    })
    await waitFor(() => expect(sendButton().disabled).toBe(false)) // finally ran

    expect(textarea().value).toBe('newer draft')
  })

  // Regression: the reply bar swallowed every failure, so a send refused
  // because a stored participant address is invalid looked like nothing
  // happened at all (the draft simply reappeared).
  it('shows why the send failed and clears the alert on the next keystroke', async () => {
    mockedSend.mockRejectedValueOnce(
      new SendFailedError('Not a single addr-spec: billing@acme.com, harvest@evil.tld', {
        userMessage: 'billing@acme.com, harvest@evil.tld is not a valid email address.',
      }),
    )
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)

    await userEvent.type(textarea(), 'hi{Enter}')

    const alert = await screen.findByRole('alert')
    expect(alert.textContent).toContain('harvest@evil.tld is not a valid email address.')

    await userEvent.type(textarea(), '!')
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('falls back to the generic line for a transport failure', async () => {
    mockedSend.mockRejectedValueOnce(new Error('offline'))
    render(<ReplyBar conversationId="c1" onSent={() => undefined} />)

    await userEvent.type(textarea(), 'hi{Enter}')

    const alert = await screen.findByRole('alert')
    expect(alert.textContent).toBe(GENERIC_SEND_ERROR)
  })

  describe('attachments', () => {
    function fileInput(): HTMLInputElement {
      return screen.getByLabelText<HTMLInputElement>('Attach files')
    }

    function pngFile(name = 'photo.png', size?: number): File {
      const file = new File([new Uint8Array([1, 2, 3, 4])], name, { type: 'image/png' })
      if (size !== undefined) vi.spyOn(file, 'size', 'get').mockReturnValue(size)
      return file
    }

    it('Enter does not send while a picked file is still processing', async () => {
      // The Send button already disables on picker.busy; the Enter path must
      // honor the same guard, or the text goes out without the file it was
      // typed alongside.
      vi.mocked(prepareAttachments).mockImplementationOnce(() => new Promise(() => {}))
      render(<ReplyBar conversationId="c1" onSent={() => undefined} />)

      await userEvent.type(textarea(), 'photo incoming')
      await userEvent.upload(fileInput(), pngFile())
      await userEvent.type(textarea(), '{Enter}')

      expect(mockedSend).not.toHaveBeenCalled()
      expect(textarea().value).toBe('photo incoming')
    })

    it('stages a picked file and lets an empty draft be sent', async () => {
      render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
      expect(
        screen.getByRole<HTMLButtonElement>('button', { name: 'Add attachment' }).disabled,
      ).toBe(false)
      // An attachment alone is a message; iOS allows a bodiless photo send.
      expect(sendButton().disabled).toBe(true)

      await userEvent.upload(fileInput(), pngFile())

      expect(await screen.findByAltText('photo.png')).toBeTruthy()
      await waitFor(() => expect(sendButton().disabled).toBe(false))
    })

    it('passes the staged files to sendMessage and clears the strip', async () => {
      render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
      await userEvent.upload(fileInput(), pngFile())
      await screen.findByAltText('photo.png')

      await userEvent.click(sendButton())

      expect(mockedSend).toHaveBeenCalledWith(
        expect.objectContaining({
          conversationId: 'c1',
          body: '',
          attachments: [expect.objectContaining({ filename: 'photo.png', mimeType: 'image/png' })],
        }),
      )
      await waitFor(() => expect(screen.queryByAltText('photo.png')).toBeNull())
    })

    it('refuses an oversize file and says which one (iOS skipped it silently)', async () => {
      render(<ReplyBar conversationId="c1" onSent={() => undefined} />)

      await userEvent.upload(fileInput(), pngFile('huge.png', 26 * 1024 * 1024))

      const alert = await screen.findByRole('alert')
      expect(alert.textContent).toContain('huge.png')
      expect(screen.queryByAltText('huge.png')).toBeNull()
      expect(sendButton().disabled).toBe(true)
    })

    it('removes a staged file', async () => {
      render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
      await userEvent.upload(fileInput(), pngFile())
      await screen.findByAltText('photo.png')

      await userEvent.click(screen.getByRole('button', { name: 'Remove photo.png' }))

      expect(screen.queryByAltText('photo.png')).toBeNull()
      expect(sendButton().disabled).toBe(true)
    })

    it('restores the draft and the files when the send failed with nothing kept', async () => {
      mockedSend.mockRejectedValueOnce(new SendFailedError('nope'))
      render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
      await userEvent.upload(fileInput(), pngFile())
      await screen.findByAltText('photo.png')
      await userEvent.type(textarea(), 'here you go')

      await userEvent.click(sendButton())

      await waitFor(() => expect(textarea().value).toBe('here you go'))
      expect(screen.getByAltText('photo.png')).toBeTruthy()
    })

    // Regression guard: a failed send that KEEPS the message leaves the body
    // and the files in a retryable bubble. Putting them back in the composer
    // too would send the whole thing twice the moment the retry succeeds.
    it('does not restore the draft or the files when the failure kept a bubble', async () => {
      mockedSend.mockRejectedValueOnce(
        new SendFailedError('boom', { keptFailedMessage: true, conversationId: 'c1' }),
      )
      render(<ReplyBar conversationId="c1" onSent={() => undefined} />)
      await userEvent.upload(fileInput(), pngFile())
      await screen.findByAltText('photo.png')
      await userEvent.type(textarea(), 'here you go')

      await userEvent.click(sendButton())

      await waitFor(() => expect(screen.getAllByRole('alert').length).toBeGreaterThan(0))
      expect(textarea().value).toBe('')
      expect(screen.queryByAltText('photo.png')).toBeNull()
    })
  })
})
