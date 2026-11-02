// Conversation-wide Gmail actions may name only rows with a Gmail id of their
// own (MessageActions.gmailMessageIDForConversationAction): one local UUID in
// the single batchModify makes Gmail reject the whole request.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { OutboundSendRow } from '@/db/types'
import { archiveConversation, reportSpam } from './messageActions'
import { messageIdForOptimisticSend } from './mimeBuilder'
import { AMBIGUOUS_SEND_STATUS } from './send'
import { convoRow, makeTestDb, msgRow, NOW } from './testSupport'

function makeJournal(
  overrides: Partial<OutboundSendRow> & Pick<OutboundSendRow, 'id'>,
): OutboundSendRow {
  return {
    conversationId: 'c1',
    newlyInsertedConversation: 0,
    createdAt: NOW,
    status: 'pending',
    conversationSnapshot: null,
    remoteCommittedMessageId: '',
    remoteCommittedThreadId: '',
    ...overrides,
  }
}

describe('remoteActionableIds', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.messages.add(
      msgRow({ id: 'g_orig', conversationId: 'c1', internalDate: NOW - 60_000 }),
    )
  })

  afterEach(async () => {
    await db.delete()
  })

  async function queuedIds(): Promise<string[][]> {
    return (await db.pendingActions.toArray()).map((action) => action.messageIds)
  }

  // Revert-check: isLocalOptimisticRow's sendState 'failed' clause — the old
  // filter excluded only 'pending', so the failed bubble's UUID was enqueued.
  // The bubble is older than the stale window, so replayAbandonedSends has
  // already swept its (non-forward) 'failed' journal: the row's own state is
  // the only thing left to recognize it by.
  it('reportSpam leaves a retained failed bubble out of the batch but still labels it locally', async () => {
    await db.messages.add(
      msgRow({
        id: 'u_failed',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'failed',
        labelIds: ['SENT'],
        hasAttachments: 1,
        rfcMessageId: messageIdForOptimisticSend('u_failed'),
        internalDate: NOW - 60 * 60 * 1000,
      }),
    )

    await reportSpam(db, 'c1', NOW)

    expect(await queuedIds()).toEqual([['g_orig']])
    expect((await db.messages.get('u_failed'))?.labelIds).toContain('SPAM')
    expect((await db.conversations.get('c1'))?.isArchived).toBe(1)
  })

  // Revert-check: remoteActionableIds as a whole. HONEST SCOPE: a
  // delivery-unknown row is excluded twice over — by isLocalOptimisticRow's
  // deterministic Message-ID clause and by the outboundSends lookup (its
  // 'ambiguous' journal lives as long as the row) — so removing either guard
  // alone leaves this green.
  it('reportSpam leaves a delivery-unknown row (shown as sent under its local id) out of the batch', async () => {
    await db.messages.add(
      msgRow({
        id: 'u_amb',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'sent',
        labelIds: ['SENT'],
        rfcMessageId: messageIdForOptimisticSend('u_amb'),
        internalDate: NOW - 1000,
      }),
    )
    await db.outboundSends.add({
      ...makeJournal({ id: 'u_amb' }),
      status: AMBIGUOUS_SEND_STATUS,
    } as unknown as OutboundSendRow)

    await reportSpam(db, 'c1', NOW)

    expect(await queuedIds()).toEqual([['g_orig']])
  })

  // Revert-check: the outboundSends lookup in remoteActionableIds.
  it('excludes any row an outbound journal still names, whatever its stored identity says', async () => {
    // A row persisted by an older build: no deterministic Message-ID, already
    // marked sent, but its journal has not been finalized.
    await db.messages.add(
      msgRow({
        id: 'u_legacy',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'sent',
        labelIds: ['SENT'],
        rfcMessageId: '',
        internalDate: NOW - 1000,
      }),
    )
    await db.outboundSends.add(makeJournal({ id: 'u_legacy', status: 'committed' }))

    await reportSpam(db, 'c1', NOW)

    expect(await queuedIds()).toEqual([['g_orig']])
  })

  it('still excludes a send in flight and keeps Gmail ids', async () => {
    await db.messages.bulkAdd([
      msgRow({
        id: 'u_pending',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'pending',
        labelIds: ['SENT', 'INBOX'],
        internalDate: NOW - 1000,
      }),
      msgRow({ id: 'g_two', conversationId: 'c1', internalDate: NOW - 500 }),
    ])

    await archiveConversation(db, 'c1', NOW)

    const queued = await queuedIds()
    expect(queued).toHaveLength(1)
    expect(new Set(queued[0])).toEqual(new Set(['g_orig', 'g_two']))
  })

  it('enqueues nothing when every affected row is local', async () => {
    await db.messages.delete('g_orig')
    await db.messages.add(
      msgRow({
        id: 'u_only',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'failed',
        labelIds: ['SENT'],
        internalDate: NOW - 1000,
      }),
    )

    await reportSpam(db, 'c1', NOW)

    expect(await db.pendingActions.count()).toBe(0)
  })
})
