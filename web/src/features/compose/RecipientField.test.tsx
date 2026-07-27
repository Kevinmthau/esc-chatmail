import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { makeTestDb, seedAccount } from '@/outbox/testSupport'
import { RecipientField } from './RecipientField'
import { validRecipientEmails, type RecipientChipData } from './recipients'

// Vitest globals are off, so RTL cannot register its own auto-cleanup.
afterEach(cleanup)

/** Stateful host mirroring how ComposeDialog owns the chip list. */
function Host({ initial = [] }: { initial?: RecipientChipData[] }) {
  const [chips, setChips] = useState<RecipientChipData[]>(initial)
  return (
    <div>
      <RecipientField chips={chips} onChipsChange={setChips} />
      {/* Plain div: <output> has an implicit "status" role that would collide
          with the field's aria-live region. */}
      <div data-testid="send-emails">{validRecipientEmails(chips).join(';')}</div>
    </div>
  )
}

describe('RecipientField', () => {
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

  const input = () => screen.getByRole('combobox', { name: 'To:' })

  it('commits a chip when a comma is typed', async () => {
    const user = userEvent.setup()
    render(<Host />)

    await user.type(input(), 'alice@example.com,')

    expect(screen.getByRole('button', { name: 'Remove alice@example.com' })).toBeTruthy()
    expect((input() as HTMLInputElement).value).toBe('')
    expect(screen.getByTestId('send-emails').textContent).toBe('alice@example.com')
  })

  it('commits a chip on Enter and announces it politely', async () => {
    const user = userEvent.setup()
    render(<Host />)

    await user.type(input(), 'bob@example.com{Enter}')

    expect(screen.getByRole('button', { name: 'Remove bob@example.com' })).toBeTruthy()
    expect(screen.getByRole('status').textContent).toContain('Added bob@example.com')
  })

  it('keeps invalid chips in the danger tint and excludes them from send', async () => {
    const user = userEvent.setup()
    render(<Host />)

    await user.type(input(), 'notanemail{Enter}')
    await user.type(input(), 'valid@example.com{Enter}')

    const invalidChip = screen
      .getByRole('button', { name: 'Remove notanemail' })
      .closest('[data-valid]')
    expect(invalidChip?.getAttribute('data-valid')).toBe('false')
    expect(invalidChip?.className).toContain('text-danger')

    const validChip = screen
      .getByRole('button', { name: 'Remove valid@example.com' })
      .closest('[data-valid]')
    expect(validChip?.getAttribute('data-valid')).toBe('true')

    expect(screen.getByTestId('send-emails').textContent).toBe('valid@example.com')
  })

  it('removes the last chip with Backspace on an empty input', async () => {
    const user = userEvent.setup()
    render(<Host />)

    await user.type(input(), 'a@example.com,b@example.com,')
    await user.keyboard('{Backspace}')

    expect(screen.queryByRole('button', { name: 'Remove b@example.com' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Remove a@example.com' })).toBeTruthy()
    expect(screen.getByRole('status').textContent).toContain('Removed b@example.com')
  })

  it('removes a chip via its remove button', async () => {
    const user = userEvent.setup()
    render(<Host />)

    await user.type(input(), 'a@example.com,')
    await user.click(screen.getByRole('button', { name: 'Remove a@example.com' }))

    expect(screen.queryByRole('button', { name: 'Remove a@example.com' })).toBeNull()
    expect(screen.getByTestId('send-emails').textContent).toBe('')
  })

  it('commits valid text on blur but leaves invalid text in the input', async () => {
    const user = userEvent.setup()
    render(<Host />)

    await user.type(input(), 'carl@example.com')
    fireEvent.blur(input())
    expect(screen.getByRole('button', { name: 'Remove carl@example.com' })).toBeTruthy()

    await user.type(input(), 'garbage')
    fireEvent.blur(input())
    expect(screen.queryByRole('button', { name: 'Remove garbage' })).toBeNull()
    expect((input() as HTMLInputElement).value).toBe('garbage')
  })

  // Regression: the chip gate used to accept anything matching /.+@.+\..+/,
  // so an Outlook-style paste committed as ONE "valid" chip that the MIME
  // builder then refuses — the send failed (or, before the builder threw,
  // silently reached nobody). Multi-address pastes must become real chips.
  describe('multi-address pastes', () => {
    it('splits a semicolon-joined paste into separate valid chips', async () => {
      const user = userEvent.setup()
      render(<Host />)

      await user.click(input())
      await user.paste('a@b.com; c@d.com')
      await user.keyboard('{Enter}')

      expect(screen.getByRole('button', { name: 'Remove a@b.com' })).toBeTruthy()
      expect(screen.getByRole('button', { name: 'Remove c@d.com' })).toBeTruthy()
      expect(screen.getByTestId('send-emails').textContent).toBe('a@b.com;c@d.com')
    })

    it('splits a space-joined paste into separate valid chips', async () => {
      const user = userEvent.setup()
      render(<Host />)

      await user.click(input())
      await user.paste('a@b.com c@d.com')
      await user.keyboard('{Enter}')

      expect(screen.getByTestId('send-emails').textContent).toBe('a@b.com;c@d.com')
    })

    it('never chops a name typed for autocomplete into chips', async () => {
      const user = userEvent.setup()
      render(<Host />)

      await user.type(input(), 'john sm{Enter}')

      expect(screen.getByRole('button', { name: 'Remove john sm' })).toBeTruthy()
      expect(screen.getByTestId('send-emails').textContent).toBe('')
    })

    it('marks a pasted name-addr invalid instead of sending text the builder refuses', async () => {
      const user = userEvent.setup()
      render(<Host />)

      await user.click(input())
      await user.paste('Bob Smith <bob@example.com>')
      await user.keyboard('{Enter}')

      const chip = screen
        .getByRole('button', { name: 'Remove Bob Smith <bob@example.com>' })
        .closest('[data-valid]')
      expect(chip?.getAttribute('data-valid')).toBe('false')
      expect(screen.getByTestId('send-emails').textContent).toBe('')
    })
  })

  it('dedupes chips by normalized address', async () => {
    const user = userEvent.setup()
    render(<Host />)

    await user.type(input(), 'dave@example.com,')
    await user.type(input(), 'DAVE@Example.com{Enter}')

    expect(screen.getAllByRole('button', { name: /Remove dave@example\.com/i })).toHaveLength(1)
    expect((input() as HTMLInputElement).value).toBe('')
    expect(screen.getByTestId('send-emails').textContent).toBe('dave@example.com')
  })

  describe('autocomplete', () => {
    beforeEach(async () => {
      await db.people.bulkAdd([
        { email: 'alice@example.com', displayName: 'Alice Anderson' },
        { email: 'anna@example.com', displayName: 'Anna Baker' },
        { email: 'bob@example.com', displayName: 'Bob Jones' },
      ])
    })

    it('lists matches and supports ArrowDown + Enter selection', async () => {
      const user = userEvent.setup()
      render(<Host />)

      await user.type(input(), 'a')
      const options = await screen.findAllByRole('option')
      expect(options).toHaveLength(2)
      expect(options[0]?.textContent).toContain('alice@example.com')

      await user.keyboard('{ArrowDown}{ArrowDown}')
      await waitFor(() =>
        expect(screen.getAllByRole('option')[1]?.getAttribute('aria-selected')).toBe('true'),
      )

      await user.keyboard('{Enter}')
      expect(screen.getByRole('button', { name: 'Remove anna@example.com' })).toBeTruthy()
      expect((input() as HTMLInputElement).value).toBe('')
      expect(screen.queryByRole('listbox')).toBeNull()
    })

    it('selects a match on click', async () => {
      const user = userEvent.setup()
      render(<Host />)

      await user.type(input(), 'bob')
      const option = await screen.findByRole('option', { name: /Bob Jones/ })
      await user.click(option)

      expect(screen.getByRole('button', { name: 'Remove bob@example.com' })).toBeTruthy()
    })

    it('excludes already-chipped people from suggestions', async () => {
      const user = userEvent.setup()
      render(<Host />)

      await user.type(input(), 'anna@example.com,')
      await user.type(input(), 'ann')

      // Wait past the debounce, then confirm no suggestion resurfaces Anna.
      await new Promise((resolve) => setTimeout(resolve, 300))
      expect(screen.queryByRole('option')).toBeNull()
    })
  })
})
