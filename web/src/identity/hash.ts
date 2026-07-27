// Synchronous SHA-256 for identity hashing. @noble/hashes is used instead of
// Web Crypto because crypto.subtle is async and identity hashes must be
// computable inside Dexie transactions (which auto-commit across non-Dexie
// awaits) — and because it runs identically under Node in tests.
import { sha256 } from '@noble/hashes/sha256'
import { bytesToHex } from '@noble/hashes/utils'

export function sha256Hex(input: string): string {
  return bytesToHex(sha256(new TextEncoder().encode(input)))
}
