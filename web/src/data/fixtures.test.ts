import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ChatmailDB } from '@/db/schema'
import { FIXTURES_SEEDED_KEY, seedFixturesOnce } from './fixtures'

const NOW = 1_800_000_000_000

describe('demo fixtures', () => {
  let db: ChatmailDB

  beforeEach(() => {
    db = new ChatmailDB(`test_fixtures_${crypto.randomUUID()}`)
  })

  afterEach(async () => {
    await db.delete()
  })

  it('seeds once and is idempotent on re-run', async () => {
    await expect(seedFixturesOnce(db, NOW)).resolves.toBe(true)

    const conversationCount = await db.conversations.count()
    const messageCount = await db.messages.count()
    const peopleCount = await db.people.count()
    expect(conversationCount).toBe(12)
    expect(messageCount).toBeGreaterThan(12)
    expect(peopleCount).toBeGreaterThan(5)
    expect(await db.syncState.get(FIXTURES_SEEDED_KEY)).toBeDefined()

    // Second call must be a no-op (returns false, changes nothing).
    await expect(seedFixturesOnce(db, NOW + 1000)).resolves.toBe(false)
    expect(await db.conversations.count()).toBe(conversationCount)
    expect(await db.messages.count()).toBe(messageCount)
    expect((await db.syncState.get(FIXTURES_SEEDED_KEY))?.value).toBe(NOW)
  })

  it('seeds mixed content: pinned, group, unread, and a newsletter HTML body', async () => {
    await seedFixturesOnce(db, NOW)

    const conversations = await db.conversations.toArray()
    expect(conversations.filter((c) => c.pinned === 1).length).toBeGreaterThan(0)
    expect(conversations.filter((c) => c.type === 'group').length).toBeGreaterThan(0)
    expect(conversations.filter((c) => c.inboxUnreadCount > 0).length).toBeGreaterThan(0)
    expect(conversations.every((c) => c.isArchived === 0)).toBe(true)

    const newsletters = await db.messages
      .where('id')
      .startsWith('demo-m-')
      .filter((m) => m.isNewsletter === 1)
      .toArray()
    expect(newsletters.length).toBeGreaterThan(0)
    const body = await db.bodies.get(newsletters[0]!.id)
    expect(body?.html).toContain('The Daily Digest')

    // Account row exists so alias-dependent lookups work in demo mode.
    expect(await db.accounts.get('demo@example.com')).toBeDefined()
  })

  it('keeps row-visible conversation fields consistent with their messages', async () => {
    await seedFixturesOnce(db, NOW)

    for (const convo of await db.conversations.toArray()) {
      const messages = await db.messages
        .where('id')
        .startsWith('demo-m-')
        .filter((m) => m.conversationId === convo.id)
        .toArray()
      expect(messages.length).toBeGreaterThan(0)

      const newest = Math.max(...messages.map((m) => m.internalDate))
      expect(convo.lastMessageDate).toBe(newest)

      const inbox = messages.filter((m) => m.labelIds.includes('INBOX'))
      expect(convo.hasInbox).toBe(inbox.length > 0 ? 1 : 0)
      expect(convo.inboxUnreadCount).toBe(inbox.filter((m) => m.isUnread === 1).length)

      // Timestamps are spread into the past, never the future.
      expect(convo.lastMessageDate).toBeLessThanOrEqual(NOW)
    }
  })
})
