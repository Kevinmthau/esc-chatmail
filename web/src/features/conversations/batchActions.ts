// Batch dispatch for multi-select list actions.
//
// Each per-conversation action in data/actions applies the change locally and
// enqueues ONE durable pending action, so batching is a loop — but the loop is
// deliberately sequential, for two reasons:
//
// - Ordering. pendingActions drains in strict createdAt order, tiebroken by the
//   auto-increment row id. Awaiting each enqueue in turn keeps the queue in the
//   same order the user's selection was applied locally; firing them
//   concurrently would let Dexie interleave the writes and reorder the drain.
// - Contention. Every action opens an rw transaction over the same three
//   tables; running N of them at once buys nothing and serializes anyway.
//
// Failures are collected rather than thrown, so a partial failure can be
// reported as one — the caller must not exit select mode claiming success.

export interface BatchActionResult {
  succeeded: readonly string[]
  failed: readonly string[]
}

export async function runBatchAction(
  conversationIds: readonly string[],
  apply: (conversationId: string) => Promise<void>,
): Promise<BatchActionResult> {
  const succeeded: string[] = []
  const failed: string[] = []
  for (const conversationId of conversationIds) {
    try {
      await apply(conversationId)
      succeeded.push(conversationId)
    } catch {
      failed.push(conversationId)
    }
  }
  return { succeeded, failed }
}

/** "1 conversation" / "3 conversations" — used in the action bar's aria-labels. */
export function conversationCountLabel(count: number): string {
  return `${count} conversation${count === 1 ? '' : 's'}`
}
