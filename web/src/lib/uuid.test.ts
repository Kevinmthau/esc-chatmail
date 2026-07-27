import { afterEach, describe, expect, it, vi } from 'vitest'
import { newId } from './uuid'

const V4_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

afterEach(() => {
  vi.unstubAllGlobals()
})

/** A `crypto` global missing `randomUUID`, as an insecure (plain-http) origin exposes it. */
function stubInsecureContext(): void {
  vi.stubGlobal('crypto', {
    getRandomValues: <T extends ArrayBufferView>(array: T): T => {
      const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength)
      for (let i = 0; i < bytes.length; i += 1) bytes[i] = (i * 37 + 11) % 256
      return array
    },
  })
}

describe('newId', () => {
  it('produces v4-shaped ids', () => {
    expect(newId()).toMatch(V4_SHAPE)
  })

  it('does not repeat', () => {
    const ids = new Set(Array.from({ length: 500 }, () => newId()))
    expect(ids.size).toBe(500)
  })

  it('falls back to getRandomValues when randomUUID is missing (insecure context)', () => {
    stubInsecureContext()
    // Pre-fix this threw "crypto.randomUUID is not a function".
    const id = newId()
    expect(id).toMatch(V4_SHAPE)
    // The stub is deterministic, so the version/variant stamping is pinned too:
    // byte 6 = 0xe9 -> 0x49, byte 8 = 0x33 -> 0xb3.
    expect(id).toBe('0b30557a-9fc4-490e-b358-7da2c7ec1136')
  })

  it('falls back to Math.random when Web Crypto is absent entirely', () => {
    vi.stubGlobal('crypto', undefined)
    const ids = new Set(Array.from({ length: 200 }, () => newId()))
    expect(ids.size).toBe(200)
    for (const id of ids) expect(id).toMatch(V4_SHAPE)
  })

  it('never calls randomUUID when it is unavailable but getRandomValues is', () => {
    const getRandomValues = vi.fn(<T extends ArrayBufferView>(array: T): T => array)
    vi.stubGlobal('crypto', { getRandomValues })
    newId()
    expect(getRandomValues).toHaveBeenCalledTimes(1)
  })
})
