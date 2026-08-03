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

// A real 1×1 PNG (so the browser's own decoder runs) well inside the 4096px
// cap, which means the picker attaches it untouched under its own name.
// Relative to the runner's cwd, which is `web/`.
const PIXEL_PNG = 'e2e/fixtures/pixel.png'

test('attaches a file, sends it, and renders it in the bubble', async ({ page }) => {
  await openChats(page)
  await page.getByText('Alice Chen', { exact: true }).first().click()

  await page.locator('input[type="file"]').setInputFiles(PIXEL_PNG)

  // Staged in the strip above the composer, with a working thumbnail.
  const strip = page.getByRole('list', { name: 'Attachments' })
  await expect(strip.getByAltText('pixel.png')).toBeVisible()

  await page.getByRole('button', { name: 'Send' }).click()

  // The bytes are local, so the sent bubble shows the image itself — never a
  // download control pointing at an attachment the server has not seen.
  const scroller = page.getByTestId('chat-scroller')
  await expect(scroller.getByRole('button', { name: 'View pixel.png' })).toBeVisible()
  await expect(strip).toHaveCount(0)
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

test('calendar invite renders the event card and opens the reader', async ({ page }) => {
  await openChats(page)
  await page.getByText('Fatima Khan', { exact: true }).first().click()

  const card = page.getByTestId('calendar-invite-card')
  await expect(card).toBeVisible()
  await expect(card.getByText('Book club — March pick')).toBeVisible()
  await expect(card.getByText('Hosted by Fatima Khan')).toBeVisible()
  await expect(card.getByText('Fatima’s place')).toBeVisible()

  // The card reserves a fixed height, and nothing inside it overflows: the chat
  // scroll engine compensates against measured row heights.
  const box = await card.boundingBox()
  expect(box?.height).toBe(204)
  const overflows = await card.evaluate((el) => el.scrollHeight > el.clientHeight)
  expect(overflows).toBe(false)

  // frameLocator (not page.frames()) so the assertion waits for the viewer
  // document to navigate and paint instead of racing it.
  await page.getByRole('link', { name: /open calendar invite/i }).click()
  await expect(page.frameLocator('dialog iframe').getByText('You have been invited')).toBeVisible()
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

/** The capsule is rendered for both layouts; only one is ever on screen. */
function searchBox(page: Page) {
  return page.getByRole('searchbox', { name: 'Search conversations' }).filter({ visible: true })
}

test('search filters the list by name, survives reload, and clears', async ({ page }) => {
  await openChats(page)
  const search = searchBox(page)

  await search.fill('fatima')
  await expect(page.getByText('Fatima Khan').first()).toBeVisible()
  await expect(page.getByText('Alice Chen', { exact: true })).toBeHidden()
  await expect(page).toHaveURL(/[?&]q=fatima/)

  // A reload re-applies the query from ?q= and refills the field.
  await page.reload()
  await expect(search).toHaveValue('fatima')
  await expect(page.getByText('Fatima Khan').first()).toBeVisible()
  await expect(page.getByText('Alice Chen', { exact: true })).toBeHidden()

  // A miss gets the search-specific empty state, never "No conversations yet".
  await search.fill('zzzzz')
  await expect(page.getByText('No results for “zzzzz”')).toBeVisible()
  await expect(page.getByText('No conversations yet')).toBeHidden()

  await page.getByRole('button', { name: 'Clear search' }).filter({ visible: true }).click()
  await expect(page.getByText('Alice Chen', { exact: true }).first()).toBeVisible()
  await expect(page).not.toHaveURL(/[?&]q=/)
})

test('search matches the snippet, and composes with the unread filter', async ({ page }) => {
  await openChats(page)
  const search = searchBox(page)

  // "book club" appears only in Fatima's preview text, not in any name.
  await search.fill('book club')
  await expect(page.getByText('Fatima Khan').first()).toBeVisible()
  await expect(page.getByText('Alice Chen', { exact: true })).toBeHidden()

  // Fatima's chat is read, so layering Unread on top empties the results —
  // the filter still applies rather than being replaced by the search.
  await page.getByRole('button', { name: 'All' }).filter({ visible: true }).click()
  await page.getByRole('menuitem', { name: 'Unread' }).click()
  await expect(page).toHaveURL(/[?&]filter=unread/)
  await expect(page).toHaveURL(/[?&]q=book\+club/)
  await expect(page.getByText('No results for “book club”')).toBeVisible()

  // Widening the query inside the Unread filter shows unread rows only.
  await search.fill('a')
  await expect(page.getByRole('link', { name: /, \d+ unread$/ }).first()).toBeVisible()
  await expect(page.getByRole('link', { name: /, read$/ })).toHaveCount(0)
})

test('forward a message to a typed address', async ({ page }) => {
  await openChats(page)
  await page.getByText('The Daily Digest', { exact: true }).first().click()

  // Right-click (long-press on touch) the bubble to open the message menu.
  await page
    .getByRole('link', { name: /open email/i })
    .first()
    .click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Forward' }).click()

  // Forward mode: 'Fwd: '-prefixed subject, the forwarded block prefilled into
  // the body, and empty recipients.
  const dialog = page.locator('dialog[open]')
  await expect(dialog.getByRole('heading', { name: 'Forward' })).toBeVisible()
  await expect(dialog.getByLabel('Subject:')).toHaveValue('Fwd: The Daily Digest — Tuesday edition')
  await expect(dialog.getByLabel('Message body')).toHaveValue(
    /---------- Forwarded message ---------[\s\S]*From: The Daily Digest/,
  )
  const to = dialog.getByRole('combobox', { name: /to/i })
  await expect(to).toHaveValue('')

  await to.fill('forwardee@example.com')
  await to.press('Enter')
  await dialog.getByRole('button', { name: 'Send' }).click()

  // The forward commits through the optimistic pipeline into its own chat.
  await expect(page.getByTestId('chat-scroller').getByText('Forwarded message')).toBeVisible()
  await expect(page.locator('dialog[open]')).toHaveCount(0)
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
