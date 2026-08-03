import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ChatmailDB, setDBForTests } from '@/db/schema'
import { seedFixturesOnce } from '@/data/fixtures'
import { configureDataActions, sendMessage } from '@/data/actions'

// Demo mode runs the REAL optimistic-send pipeline against a stub transport
// that commits locally — the send UX must work without any OAuth broker.

let db: ChatmailDB

beforeEach(async () => {
  db = new ChatmailDB(`test-${crypto.randomUUID()}`)
  setDBForTests(db)
  await seedFixturesOnce(db)
  configureDataActions(null, { demo: true })
})

afterEach(async () => {
  configureDataActions(null)
  setDBForTests(null)
  await db.delete()
})

describe('demo-mode send', () => {
  it('commits a reply locally through the optimistic pipeline', async () => {
    const conversation = (await db.conversations.toCollection().first())!
    const result = await sendMessage({ conversationId: conversation.id, body: 'Demo hello' })

    expect(result.messageId).toMatch(/^demo-/)
    const sent = await db.messages.get(result.messageId)
    expect(sent).toBeDefined()
    expect(sent!.sendState).toBe('sent')
    expect(sent!.isFromMe).toBe(1)
    expect(sent!.chatPreviewText).toBe('Demo hello')

    const journal = await db.outboundSends.toArray()
    expect(journal.every((j) => j.status === 'finalized')).toBe(true)

    const conv = await db.conversations.get(conversation.id)
    expect(conv!.snippet).toBe('Demo hello')
  })

  it('still throws when signed out without demo mode', async () => {
    configureDataActions(null)
    const conversation = (await db.conversations.toCollection().first())!
    await expect(sendMessage({ conversationId: conversation.id, body: 'x' })).rejects.toThrow(
      'Not signed in',
    )
  })
})
