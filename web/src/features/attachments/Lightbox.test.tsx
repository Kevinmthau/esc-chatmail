// Lightbox keyboard navigation and bounds.

import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'
import { makeTestDb } from '@/outbox/testSupport'
import { Lightbox } from './Lightbox'

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
  setDBForTests(db)
})

afterEach(async () => {
  cleanup()
  setDBForTests(null)
  await db.delete()
})

function image(id: string, filename: string): AttachmentRow {
  return {
    id,
    messageId: 'm1',
    gmailAttachmentId: `g_${id}`,
    contentId: '',
    filename,
    mimeType: 'image/png',
    byteSize: 100,
    width: 0,
    height: 0,
    state: 'queued',
    lastDownloadFailedAt: 0,
  }
}

const IMAGES = [image('a1', 'one.png'), image('a2', 'two.png'), image('a3', 'three.png')]

describe('Lightbox', () => {
  it('shows the current image position and filename', () => {
    render(<Lightbox images={IMAGES} initialIndex={0} onClose={() => undefined} />)
    expect(screen.getByText('one.png')).toBeTruthy()
    expect(screen.getByText('· 1 of 3')).toBeTruthy()
  })

  it('navigates with ArrowRight and ArrowLeft', () => {
    render(<Lightbox images={IMAGES} initialIndex={0} onClose={() => undefined} />)

    fireEvent.keyDown(window, { key: 'ArrowRight' })
    expect(screen.getByText('two.png')).toBeTruthy()
    expect(screen.getByText('· 2 of 3')).toBeTruthy()

    fireEvent.keyDown(window, { key: 'ArrowRight' })
    expect(screen.getByText('three.png')).toBeTruthy()

    fireEvent.keyDown(window, { key: 'ArrowLeft' })
    expect(screen.getByText('two.png')).toBeTruthy()
  })

  it('clamps keyboard navigation at both ends', () => {
    render(<Lightbox images={IMAGES} initialIndex={2} onClose={() => undefined} />)

    fireEvent.keyDown(window, { key: 'ArrowRight' })
    expect(screen.getByText('three.png')).toBeTruthy()

    fireEvent.keyDown(window, { key: 'ArrowLeft' })
    fireEvent.keyDown(window, { key: 'ArrowLeft' })
    fireEvent.keyDown(window, { key: 'ArrowLeft' })
    expect(screen.getByText('one.png')).toBeTruthy()
  })

  it('disables prev at the start and next at the end', async () => {
    render(<Lightbox images={IMAGES} initialIndex={0} onClose={() => undefined} />)

    const prev = screen.getByRole<HTMLButtonElement>('button', { name: 'Previous image' })
    const next = screen.getByRole<HTMLButtonElement>('button', { name: 'Next image' })
    expect(prev.disabled).toBe(true)
    expect(next.disabled).toBe(false)

    await userEvent.click(next)
    await userEvent.click(next)
    expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Next image' }).disabled).toBe(
      true,
    )
  })

  it('hides the arrows for a single image and shows the placeholder when not downloaded', () => {
    render(
      <Lightbox images={[image('a1', 'only.png')]} initialIndex={0} onClose={() => undefined} />,
    )
    expect(screen.queryByRole('button', { name: 'Next image' })).toBeNull()
    expect(screen.getByText('Image not downloaded')).toBeTruthy()
  })

  it('invokes onClose from the close button', async () => {
    const onClose = vi.fn()
    render(<Lightbox images={IMAGES} initialIndex={0} onClose={onClose} />)
    await userEvent.click(screen.getByRole('button', { name: 'Close image viewer' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
