import type { ChatmailDB } from './schema'

// The durable-storage verdict (navigator.storage.persist), under its own
// syncState key. It used to be a field of the syncProgress row, but every
// sync writer replaces that row wholesale (kv.ts setSyncProgress is a plain
// put) and the startup sync runs moments after boot records the verdict, so
// the field was gone after the first progress write of every boot, and the
// read-modify-write that set it could put a stale phase back over a sync
// write. A key the sync engine never touches is written with one put.

const STORAGE_PERSISTENT_KEY = 'storagePersistent'

/** The recorded verdict, or undefined when no boot has recorded one yet. */
export async function getStoragePersistent(db: ChatmailDB): Promise<boolean | undefined> {
  const row = await db.syncState.get(STORAGE_PERSISTENT_KEY)
  const value: unknown = row?.value
  return typeof value === 'boolean' ? value : undefined
}

export async function setStoragePersistent(db: ChatmailDB, granted: boolean): Promise<void> {
  await db.syncState.put({ key: STORAGE_PERSISTENT_KEY, value: granted })
}
