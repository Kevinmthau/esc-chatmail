import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { makeRecipientParticipantSetIdentity } from '@/identity/participantSet'
import { convoRow, makeTestDb, ME, seedAccount } from '@/outbox/testSupport'
import { makeChip, type RecipientChipData } from './recipients'
import { useRecipientDedup } from './useRecipientDedup'

afterEach(cleanup)

function Probe({ chips }: { chips: RecipientChipData[] }) {
  const match = useRecipientDedup(chips)
  return (
    <div data-testid="match">{match ? `${match.conversationId}:${match.displayName}` : 'none'}</div>
  )
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

describe('useRecipientDedup', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    setDBForTests(db)
    await seedAccount(db)
  })

  afterEach(async () => {
    setDBForTests(null)
    await db.delete()
  })

  async function seedBobConversation(overrides = {}) {
    const identity = makeRecipientParticipantSetIdentity(['bob@example.com'], new Set([ME]))
    await db.conversations.add(
      convoRow({
        id: 'c1',
        participantHash: identity?.participantHash ?? '',
        displayName: 'Bob Jones',
        ...overrides,
      }),
    )
  }

  it('finds the existing chat for the committed participant set (canonical hashing)', async () => {
    await seedBobConversation()

    // Raw, differently-cased input must still hit the same participant hash.
    render(<Probe chips={[makeChip('Bob@Example.com')!]} />)

    await waitFor(() => expect(screen.getByTestId('match').textContent).toBe('c1:Bob Jones'))
  })

  it('ignores invalid chips and reports no match without valid recipients', async () => {
    await seedBobConversation()

    render(<Probe chips={[makeChip('notanemail')!]} />)

    await sleep(100)
    expect(screen.getByTestId('match').textContent).toBe('none')
  })

  it('does not match archived-only conversation epochs', async () => {
    await seedBobConversation({ archivedAt: 123, isArchived: 1 })

    render(<Probe chips={[makeChip('bob@example.com')!]} />)

    await sleep(100)
    expect(screen.getByTestId('match').textContent).toBe('none')
  })

  it('clears the match when the chip set changes to unknown recipients', async () => {
    await seedBobConversation()

    const { rerender } = render(<Probe chips={[makeChip('bob@example.com')!]} />)
    await waitFor(() => expect(screen.getByTestId('match').textContent).toBe('c1:Bob Jones'))

    rerender(<Probe chips={[makeChip('nobody@example.com')!]} />)
    await waitFor(() => expect(screen.getByTestId('match').textContent).toBe('none'))
  })
})
