import { Blob as NodeBlob } from 'node:buffer'
import { cleanup, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ChatmailDB, setDBForTests } from '@/db/schema'
import { useAttachmentUrl } from './useAttachmentUrl'

// happy-dom's Blob does not survive fake-indexeddb's structured clone.
globalThis.Blob = NodeBlob as unknown as typeof Blob

let db: ChatmailDB
let dbCounter = 0

// Object URLs are opaque strings, so keep a url → blob map to prove WHICH
// bytes a given url is backed by.
const minted: Array<{ url: string; blob: Blob }> = []
const originalCreate = URL.createObjectURL
const originalRevoke = URL.revokeObjectURL

function blobFor(url: string | null): Blob | undefined {
  return minted.find((entry) => entry.url === url)?.blob
}

beforeEach(async () => {
  minted.length = 0
  let counter = 0
  URL.createObjectURL = (blob: Blob) => {
    const url = `blob:test/${++counter}`
    minted.push({ url, blob })
    return url
  }
  URL.revokeObjectURL = () => undefined

  db = new ChatmailDB(`test_att_url_${++dbCounter}`)
  setDBForTests(db)
  await db.blobs.bulkPut([
    { key: 'a1', blob: new Blob(['one']), byteSize: 3, lastAccessAt: 1 },
    { key: 'a2', blob: new Blob(['two']), byteSize: 3, lastAccessAt: 2 },
  ])
})

afterEach(async () => {
  cleanup()
  URL.createObjectURL = originalCreate
  URL.revokeObjectURL = originalRevoke
  setDBForTests(null)
  await db.delete()
})

describe('useAttachmentUrl', () => {
  it('resolves the stored blob for the requested attachment', async () => {
    const { result } = renderHook(() => useAttachmentUrl('a1'))

    await waitFor(() => expect(result.current).not.toBeNull())
    expect(await blobFor(result.current)?.text()).toBe('one')
  })

  it('never binds a new attachment id to the previous attachment’s blob', async () => {
    const { result, rerender } = renderHook(({ id }: { id: string }) => useAttachmentUrl(id), {
      initialProps: { id: 'a1' },
    })
    await waitFor(() => expect(result.current).not.toBeNull())
    expect(await blobFor(result.current)?.text()).toBe('one')

    // Paging the lightbox: useLiveQuery still holds a1's row for this render.
    rerender({ id: 'a2' })
    expect(result.current).toBeNull()

    await waitFor(() => expect(result.current).not.toBeNull())
    expect(await blobFor(result.current)?.text()).toBe('two')
    // No url was ever minted that pairs a2 with a1's bytes.
    expect(minted).toHaveLength(2)
  })

  it('clears the url when disabled with a null id', async () => {
    const initialProps: { id: string | null } = { id: 'a1' }
    const { result, rerender } = renderHook(
      ({ id }: { id: string | null }) => useAttachmentUrl(id),
      { initialProps },
    )
    await waitFor(() => expect(result.current).not.toBeNull())

    rerender({ id: null })
    expect(result.current).toBeNull()
  })
})
