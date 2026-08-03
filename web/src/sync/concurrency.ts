// The single bounded-concurrency primitive for sync.
//
// Every network tier the sync engine drives (message GETs, large-body /
// attachment GETs during parsing, reconciliation metadata GETs) has to be
// capped: Gmail bills 5 quota units per `messages.get` against a
// 250-unit/user/second budget, and unbounded fan-out turns one page of a
// backfill into an instant 429 wall plus hundreds of simultaneous multi-MB
// response buffers. Port of the sliding `withTaskGroup` window used by
// MessageFetcher / MessagePersister.prepareMessagesConcurrently on iOS.

export interface BoundedMapOptions {
  /**
   * Dynamic ceiling consulted before each item is claimed. Live workers retire
   * (never below one) while their count exceeds it, so a caller can shed
   * parallelism part-way through a batch — e.g. after the first 429.
   */
  limit?: () => number
}

/**
 * Runs `task` over `items` with at most `concurrency` in flight, returning the
 * results in input order.
 */
export async function mapWithConcurrency<T, R>(
  items: readonly T[],
  concurrency: number,
  task: (item: T, index: number) => Promise<R>,
  options: BoundedMapOptions = {},
): Promise<R[]> {
  const results = new Array<R>(items.length)
  if (items.length === 0) return results

  const width = Math.max(1, Math.min(Math.floor(concurrency), items.length))
  let nextIndex = 0
  let liveWorkers = width

  const worker = async (): Promise<void> => {
    for (;;) {
      if (options.limit !== undefined && liveWorkers > 1) {
        const ceiling = Math.max(1, Math.floor(options.limit()))
        if (liveWorkers > ceiling) {
          liveWorkers -= 1
          return
        }
      }

      const index = nextIndex
      if (index >= items.length) {
        liveWorkers -= 1
        return
      }
      nextIndex += 1

      const item = items[index]
      if (item === undefined) {
        liveWorkers -= 1
        return
      }
      results[index] = await task(item, index)
    }
  }

  await Promise.all(Array.from({ length: width }, () => worker()))
  return results
}
