import { test, expect, type Page } from '@playwright/test'

// Demo mode boots on a fresh origin profile per test (Playwright gives each
// test an isolated browser context, so IndexedDB starts empty and the fixture
// seed runs on first load).

async function openChats(page: Page) {
  await page.goto('/')
  await expect(page).toHaveURL(/\/chats/)
  await expect(page.getByText('Demo data')).toBeVisible()
  await expect(page.getByText('Alice Chen', { exact: true }).first()).toBeVisible()
}

test('list renders demo conversations with unread state', async ({ page }) => {
  await openChats(page)
  await expect(page.getByText('Fatima Khan').first()).toBeVisible()
  await expect(page.getByText('The Daily Digest').first()).toBeVisible()
  // At least one unread conversation exists in the fixtures.
  const unreadRows = page.getByRole('link', { name: /unread/i })
  expect(await unreadRows.count()).toBeGreaterThan(0)
})

test('open chat, bubbles render, optimistic send commits', async ({ page }) => {
  await openChats(page)
  await page.getByText('Alice Chen', { exact: true }).first().click()
  await expect(page.getByText('Want to grab lunch Thursday?')).toBeVisible()

  const input = page.getByRole('textbox', { name: 'Message' })
  await input.fill('E2E hello from Playwright')
  await page.getByRole('button', { name: /send/i }).click()

  // Optimistic bubble appears in the chat, then commits through the demo
  // transport; the list snippet updates live via the same rollup.
  const scroller = page.getByTestId('chat-scroller')
  await expect(scroller.getByText('E2E hello from Playwright')).toBeVisible()
  await expect(input).toHaveValue('')
})

test('newsletter renders as preview card and opens the sandboxed reader', async ({ page }) => {
  await openChats(page)
  await page.getByText('The Daily Digest', { exact: true }).first().click()

  // The preview card's overlay link opens the reader.
  const cardLink = page.getByRole('link', { name: /open email/i }).first()
  await expect(cardLink).toBeVisible()
  await cardLink.click()

  const readerFrame = page.locator('dialog iframe')
  await expect(readerFrame).toBeVisible()
  const sandbox = await readerFrame.getAttribute('sandbox')
  expect(sandbox).toContain('allow-scripts')
  expect(sandbox).not.toContain('allow-same-origin')

  // The email content actually painted inside the opaque frame.
  const frame = page.frames().find((f) => f.url().includes('email-frame'))
  expect(frame).toBeTruthy()
  await expect(frame!.getByText('Five things worth reading')).toBeVisible()

  await page.keyboard.press('Escape')
  await expect(page.locator('dialog[open]')).toHaveCount(0)
})

test('multi-select archives two conversations in one batch', async ({ page }) => {
  await openChats(page)

  // The group fixture is named "Alice Chen, Ben Ortiz", so match rows by an
  // exact name text node to pick the one-to-one chats.
  const optionFor = (name: string) =>
    page.getByRole('option').filter({ has: page.getByText(name, { exact: true }) })

  await page.getByRole('button', { name: 'Select', exact: true }).click()
  await optionFor('Alice Chen').click()
  await optionFor('Fatima Khan').click()

  await expect(page.getByText('2 Selected')).toBeVisible()
  await expect(optionFor('Alice Chen')).toHaveAttribute('aria-selected', 'true')

  await page.getByRole('button', { name: 'Archive 2 conversations', exact: true }).click()

  // Completing the batch leaves select mode, and both conversations drop out
  // of the active list (archive is local-first, so it lands with no network).
  await expect(page.getByRole('button', { name: 'Select', exact: true })).toBeVisible()
  await expect(page.getByRole('option')).toHaveCount(0)
  await expect(page.getByText('Alice Chen', { exact: true })).toHaveCount(0)
  await expect(page.getByText('Fatima Khan', { exact: true })).toHaveCount(0)
  await expect(page.getByText('The Daily Digest', { exact: true }).first()).toBeVisible()
})

test('compose dialog opens and dedups to an existing chat', async ({ page }) => {
  await openChats(page)
  await page.getByRole('button', { name: /new message|compose/i }).click()
  await expect(page.getByText('New Message')).toBeVisible()

  // Commit the fixture person's address as a chip; the dedup banner should
  // point at the existing Alice chat. (The field is an ARIA combobox named by
  // its "To:" label — it drives the autocomplete popup.)
  const to = page.getByRole('combobox', { name: /to/i })
  await to.fill('alice@example.com')
  await to.press('Enter')
  await expect(page.getByText(/already have a chat/i)).toBeVisible()
})

test('mobile: stacked navigation with working back', async ({ page, isMobile }) => {
  test.skip(!isMobile, 'mobile project only')
  await openChats(page)
  await page.getByText('Ben Ortiz', { exact: true }).first().click()
  await expect(page.getByText('Got it, will review tonight.').first()).toBeVisible()
  // The list pane is hidden on mobile while a chat is open.
  await expect(page.getByText('Fatima Khan')).toBeHidden()
  await page.goBack()
  await expect(page.getByText('Fatima Khan').first()).toBeVisible()
})
